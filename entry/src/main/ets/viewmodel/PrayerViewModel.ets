/**
 * PrayerViewModel.ets
 * -------------------
 * Orkestrator state halaman utama (pola MVVM ringan):
 *  onboarding permission -> lokasi -> API (cache-first) -> jadwal + countdown
 *  -> jadwalkan ReminderAgent H-10 menit.
 * Semua error dikumpulkan ke field `errorMessage` agar UI bisa menampilkan
 * pesan yang jelas (izin ditolak / gagal memuat jadwal).
 *
 * ANTI-"LOADING TERUS" (laporan user: aplikasi mentok di "Memuat jadwal
 * sholat…"). Empat lapis pertahanan, semuanya teruji terhadap kondisi nyata
 * wearable Huawei Watch (relay Bluetooth lambat, GPS lama, MyQuran kadang
 * membalas "Data not found" untuk tanggal hari ini):
 *  1. hydrateFromCache() dijalankan PALING AWAL — bila ada jadwal tersimpan,
 *     UI langsung READY seketika tanpa menunggu permission/GPS/API.
 *  2. Setiap tahap sistem (permission dialog, GPS fix, reverse geocode)
 *     dibungkus withTimeout() sendiri-sendiri — tidak ada satu pun await
 *     yang bisa menggantung tanpa batas.
 *  3. DEADLINE keseluruhan bootstrap (BOOTSTRAP_DEADLINE_MS) sebagai pagar
 *     terakhir; saat tembus, safety net jadwal default Jakarta disajikan.
 *  4. Blok finally DIJAMIN mengubah state keluar dari LOADING — layar
 *     loading tidak mungkin permanen lagi.
 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PermissionService } from '../services/PermissionService.ets';
import { LocationService } from '../services/LocationService.ets';
import { PrayerApiService } from '../services/PrayerApiService.ets';
import { ReminderService } from '../services/ReminderService.ets';
import { preference } from '../services/PreferenceService.ets';
import {
  GeoInfo, NormalizedDailySchedule, PrayerFetchResult, PrayerScheduleItem
} from '../model/PrayerModels.ets';
import { CountdownTimer, formatCountdown } from './CountdownTimer.ets';
import {
  DEFAULT_CITY, REFRESH_INTERVAL_MS, BOOTSTRAP_DEADLINE_MS
} from '../common/Constants.ets';

const DOMAIN: number = 0x0000;
const TAG: string = 'MySholat|VM';

/** Status lifecycle tampilan — enum eksplisit, bukan string bebas. */
export enum LoadState {
  IDLE = 0,
  LOADING = 1,
  READY = 2,
  ERROR_NO_PERMISSION = 3,
  ERROR_API = 4
}

@Observed
export class PrayerViewModel {
  @Track loadState: LoadState = LoadState.IDLE;
  @Track errorMessage: string = '';
  @Track cityName: string = DEFAULT_CITY;
  @Track schedule: PrayerScheduleItem[] = [];
  @Track nextPrayerName: string = '';
  @Track nextPrayerTime: string = '';
  @Track countdownText: string = '--';

  private geo: GeoInfo | null = null;
  private timer: CountdownTimer = new CountdownTimer((remainingMs: number) => {
    this.countdownText = formatCountdown(remainingMs);
    if (remainingMs <= 0) {
      // Waktu sholat tiba -> hitung ulang target berikutnya.
      this.recomputeNextPrayer();
    }
  });
  private refreshTimerId: number = -1;

  /** Entry point dari aboutToAppear/onPageShow. */
  async bootstrap(context?: common.UIAbilityContext): Promise<void> {
    this.loadState = LoadState.LOADING;
    this.errorMessage = '';

    // ── LANGKAH 0: tampilkan CACHE DULU, jaringan belakangan ──────────────
    // Ini perbaikan utama keluhan "loading terus": selama ini rantai
    // permission -> GPS -> API berjalan LENGKAP sebelum UI menampilkan apa
    // pun. Sekarang bila ada jadwal tersimpan (fresh/stale), watch langsung
    // menunjukkan jam sholat dalam <1 detik.
    await this.hydrateFromCache();

    // ── DEADLINE KESELURUHAN ──────────────────────────────────────────────
    // Seluruh pipeline dibatasi BOOTSTRAP_DEADLINE_MS. Apapun yang terjadi
    // (dialog permission menggantung, GPS tak pernah fix, promise sistem tak
    // settle), fungsi ini DIJAMIN selesai dan state tidak tertahan LOADING.
    try {
      await this.withDeadline(this.bootstrapPipeline(context), BOOTSTRAP_DEADLINE_MS);
    } catch (deadlineErr) {
      const de = deadlineErr as Error;
      hilog.warn(DOMAIN, TAG, 'Bootstrap deadline hit: %{public}s', de.message ?? String(deadlineErr));
      if (this.schedule.length === 0) {
        // Belum ada apa pun untuk ditampilkan -> safety net default Jakarta.
        this.showDefaultSchedule('Waktu muat habis — menampilkan jadwal default Jakarta.');
      } else {
        // Data cache sudah tampil — cukup beri catatan, JANGAN turunkan mutu
        // tampilan hanya karena pembaruan jaringan terlambat.
        this.errorMessage = 'Pembaruan jadwal lambat — data terakhir tetap ditampilkan.';
      }
    } finally {
      // ── JAMINAN FINAL: state TIDAK BOLEH LOADING lagi setelah bootstrap ──
      if (this.loadState === LoadState.LOADING) {
        if (this.schedule.length > 0) {
          this.loadState = LoadState.READY;
        } else {
          this.showDefaultSchedule('Gagal memuat jadwal — menampilkan jadwal default Jakarta.');
        }
      }
      this.startPeriodicRefresh();
    }
  }

  /** Rantai utama: permission -> lokasi -> fetch jadwal -> reminder. */
  private async bootstrapPipeline(context?: common.UIAbilityContext): Promise<void> {
    // 1) ONBOARDING PERMISSION — minta izin lokasi saat pertama dibuka.
    //    Dialog dibatasi 8s: pada beberapa kondisi wearable dialog tidak pernah
    //    muncul/menggantung — jangan sampai itu menahan seluruh bootstrap.
    let granted: boolean = true;
    if (context !== undefined) {
      try {
        granted = await this.withDeadline<boolean>(
          PermissionService.requestLocationPermissions(context), 8000);
      } catch (permErr) {
        // Timeout dialog -> anggap "belum diketahui"; lanjutkan dengan cache/
        // koordinat tersimpan daripada menampilkan loading kosong.
        hilog.warn(DOMAIN, TAG, 'Permission dialog timed out; continuing with cached geo.');
        granted = true;
      }
    }
    if (!granted) {
      this.loadState = LoadState.ERROR_NO_PERMISSION;
      this.errorMessage = 'Izin lokasi ditolak. Aktifkan lewat Settings > Apps > MySholat agar jadwal sesuai kotamu.';
      // Tetap tampilkan jadwal cache/default Jakarta supaya watch berguna.
      if (this.schedule.length === 0) {
        this.showDefaultSchedule(this.errorMessage);
      }
      return;
    }

    // 1b) Izin notifikasi untuk reminder (best-effort, dibatasi 5s).
    try {
      await this.withDeadline(ReminderService.ensureNotificationEnabled(), 5000);
    } catch (notifErr) {
      hilog.warn(DOMAIN, TAG, 'ensureNotificationEnabled skipped (timeout/error).');
    }

    // 2) DETEKSI LOKASI (+ reverse geocoding nama kota).
    //    LocationService internal sudah ber-timeout (locatingTimeoutMs 10s +
    //    wrapper 15s + fallback cache/default) — dibatasi 12s di sini agar
    //    masih ada jatah waktu untuk langkah API sebelum deadline bootstrap.
    try {
      const geo: GeoInfo = await this.withDeadline<GeoInfo>(LocationService.getGeoInfo(), 12000);
      this.geo = geo;
      this.cityName = geo.cityName;
    } catch (geoErr) {
      // Lokasi gagal total -> fetch TETAP jalan dengan cityId default Jakarta.
      hilog.warn(DOMAIN, TAG, 'Geolocation unavailable; using cityId-only fetch.');
    }

    // 3) AMBIL JADWAL: cache-first -> MyQuran -> Aladhan (lihat PrayerApiService).
    await this.fetchScheduleAndRemind();
  }

  /** Hydrasi UI dari cache lokal — dipanggil SEBELUM jalur jaringan. */
  private async hydrateFromCache(): Promise<void> {
    const cachedRaw: string = await preference.loadCachedSchedule();
    if (cachedRaw.length === 0) { return; }
    try {
      const sched: NormalizedDailySchedule = JSON.parse(cachedRaw) as NormalizedDailySchedule;
      this.schedule = sched.toItems();
      this.recomputeNextPrayer();
      const lastDate: string = await preference.loadLastFetchDate();
      if (lastDate === PrayerApiService.todayKey()) {
        if (sched.isDefault === true) {
          // Negative cache hari ini: sajikan seketika + banner peringatan.
          this.loadState = LoadState.ERROR_API;
          this.errorMessage = 'Gagal memuat jadwal dari internet — menampilkan jadwal standar Jakarta.';
        } else {
          this.loadState = LoadState.READY;
        }
      }
      // Cache basi -> tetap tampilkan dulu; pipeline jaringan akan
      // menaikkannya ke READY/ERROR nanti (watch tidak pernah blank).
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'hydrateFromCache parse failed');
    }
  }

  /** Sajikan jadwal default Kemenag Jakarta + banner (safety net anti-blank). */
  private showDefaultSchedule(message: string): void {
    this.schedule = PrayerApiService.buildDefaultSchedule().toItems();
    this.recomputeNextPrayer();
    this.loadState = LoadState.ERROR_API;
    this.errorMessage = message;
  }

  /** Balut promise apapun dengan deadline — menolak (reject) saat tembus. */
  private withDeadline<T>(p: Promise<T>, ms: number): Promise<T> {
    return new Promise<T>((resolve: (v: T) => void, reject: (e: Error) => void) => {
      const timerId: number = setTimeout(() => {
        reject(new Error(`deadline ${ms}ms`));
      }, ms);
      p.then((v: T) => {
        clearTimeout(timerId);
        resolve(v);
      }).catch((err: Error) => {
        clearTimeout(timerId);
        reject(err instanceof Error ? err : new Error(String(err)));
      });
    });
  }

  /** Ambil jadwal + jadwalkan reminder H-10 menit. */
  private async fetchScheduleAndRemind(): Promise<void> {
    // geo boleh null (mis. lokasi gagal/telat) — orkestrator tetap jalan
    // dengan cityId default Jakarta, jadi tidak ada early-return yang
    // membuat state tertahan LOADING.
    const geo: GeoInfo | null = this.geo;

    // Orkestrator cache-first: MyQuran (cityId) -> Aladhan (lat/lon) -> stale.
    const cityId: string = await preference.loadSelectedCityId();
    const lat: number | undefined = geo !== null ? geo.latitude : undefined;
    const lon: number | undefined = geo !== null ? geo.longitude : undefined;
    const result: PrayerFetchResult =
      await PrayerApiService.getTodaysPrayerTimes(cityId, lat, lon);

    if (result.schedule === null) {
      // Tidak ada data sama sekali (jaringan gagal & cache kosong) —
      // safety net default Jakarta agar watch tidak mentok loading.
      hilog.error(DOMAIN, TAG, 'All sources failed: %{public}s', result.errorMessage);
      this.showDefaultSchedule('Gagal memuat jadwal. Periksa koneksi Bluetooth/Wi-Fi lalu coba lagi.');
      return;
    }

    // Selalu tampilkan data — fresh maupun stale — agar watch tetap berguna.
    this.schedule = result.schedule.toItems();
    if (result.isError) {
      // Data cadangan tersaji + banner peringatan (ERROR_API memicu tombol retry).
      this.loadState = LoadState.ERROR_API;
      this.errorMessage = result.errorMessage;
    } else {
      this.loadState = LoadState.READY;
      this.errorMessage = '';
    }

    this.recomputeNextPrayer();
    if (!result.isError) {
      // Hanya jadwalkan reminder bila data hari ini terjamin segar.
      await ReminderService.scheduleForToday(this.schedule);
    }
  }

  /** Tandai item yang sudah lewat & cari sholat berikutnya, lalu setel countdown. */
  recomputeNextPrayer(): void {
    const now: number = Date.now();
    let found: boolean = false;

    for (let i = 0; i < this.schedule.length; i++) {
      const item: PrayerScheduleItem = this.schedule[i];
      const passed: boolean = item.timeMs <= now;
      const isNext: boolean = !passed && !found;
      if (isNext) { found = true; }

      // Reassign array elemen agar @Track memicu re-render (ArkTS @Observed).
      const updated: PrayerScheduleItem = new PrayerScheduleItem(
        item.name, item.apiName, item.time, item.timeMs);
      updated.isPassed = passed;
      updated.isNext = isNext;
      this.schedule[i] = updated;
    }

    // Setelah Isya lewat -> "berikutnya" adalah Subuh esok hari.
    if (!found && this.schedule.length === 5) {
      const subuh: PrayerScheduleItem = this.schedule[0];
      const tomorrowSubuhMs: number = subuh.timeMs + 24 * 60 * 60 * 1000;
      this.nextPrayerName = `${subuh.name} (besok)`;
      this.nextPrayerTime = subuh.time;
      this.timer.setTarget(tomorrowSubuhMs);
    } else if (found) {
      const next: PrayerScheduleItem = this.schedule.find((p: PrayerScheduleItem) => p.isNext)!;
      this.nextPrayerName = next.name;
      this.nextPrayerTime = next.time;
      this.timer.setTarget(next.timeMs);
    } else {
      this.countdownText = '--';
      this.timer.stop();
    }
    this.schedule = [...this.schedule]; // trigger update List
  }

  /** Retry manual dari tombol di UI (saat ERROR_API). */
  async retry(context?: common.UIAbilityContext): Promise<void> {
    await this.bootstrap(context);
  }

  /** Deteksi pergantian hari: bila tanggal berubah, fetch ulang (ber-deadline). */
  async checkDayRollover(): Promise<void> {
    const cachedDate: string = await preference.loadLastFetchDate();
    if (cachedDate !== PrayerApiService.todayKey()) {
      hilog.info(DOMAIN, TAG, 'Day changed (%{public}s -> %{public}s), refetching.',
        cachedDate, PrayerApiService.todayKey());
      try {
        await this.withDeadline(this.fetchScheduleAndRemind(), BOOTSTRAP_DEADLINE_MS);
      } catch (err) {
        // Rollover gagal tepat waktu — data lama tetap tampil, bukan loading.
        hilog.warn(DOMAIN, TAG, 'Day-rollover fetch did not finish in time.');
      }
    }
  }

  onPageHide(): void {
    // Layar watch mati/background: matikan countdown utk hemat baterai.
    this.timer.stop();
    if (this.refreshTimerId !== -1) {
      clearInterval(this.refreshTimerId);
      this.refreshTimerId = -1;
    }
  }

  onPageShow(): void {
    // Kembali ke jam aplikasi: lanjutkan countdown dari target yg tersimpan.
    // Kondisi diperluas: data ERROR_API (stale/negative-cache) pun layak
    // dicek ulang per-ganti-hari, bukan hanya READY.
    if (this.schedule.length > 0 && this.loadState !== LoadState.LOADING) {
      this.recomputeNextPrayer();
      this.checkDayRollover();
    }
  }

  destroy(): void {
    this.onPageHide();
  }

  private startPeriodicRefresh(): void {
    if (this.refreshTimerId !== -1) { clearInterval(this.refreshTimerId); }
    // Interval besar (30 mnt) hanya aktif saat foreground; dibersihkan di onPageHide.
    this.refreshTimerId = setInterval(() => {
      this.checkDayRollover();
    }, REFRESH_INTERVAL_MS);
  }
}
