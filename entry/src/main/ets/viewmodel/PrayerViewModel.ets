/**
 * PrayerViewModel.ets
 * -------------------
 * Orkestrator state halaman utama (pola MVVM ringan) — LOGIKA DESAIN AWAL:
 *  onboarding permission -> lokasi (GPS) -> Aladhan API (+ cache harian)
 *  -> jadwal + countdown + JAM SAAT INI -> jadwalkan ReminderAgent H-10 menit.
 * Semua error dikumpulkan ke field `errorMessage` agar UI bisa menampilkan
 * pesan yang jelas (izin ditolak / gagal memuat jadwal).
 *
 * PERBAIKAN KELUHAN USER ("waktu muat habis" & "Coba Lagi" tidak mencari lagi):
 *  1. hydrateFromCache() dijalankan PALING AWAL — jadwal tersimpan tampil
 *     seketika tanpa menunggu permission/GPS/API.
 *  2. Setiap tahap sistem dibungkus withDeadline() — tidak ada await yang
 *     menggantung; blok finally DIJAMIN mengeluarkan state dari LOADING.
 *  3. TIDAK ADA negative-cache jadwal default lagi: tombol Refresh / Coba
 *     Lagi (refresh()) selalu melewati cache, mengambil ulang koordinat GPS
 *     terbaru (user bisa berpindah tempat), dan sungguh-sungguh memanggil
 *     API Aladhan dari awal.
 *  4. currentClock di-update tiap tick CountdownTimer -> jam saat ini tampil
 *     dan berdetak setiap detik tanpa timer tambahan.
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
  /** JAM SAAT INI "HH:mm:ss" — di-update tiap tick countdown (lihat onTick). */
  @Track currentClock: string = '--:--:--';
  /** true selama proses refresh manual berjalan (mencegah tap ganda). */
  @Track isRefreshing: boolean = false;

  private geo: GeoInfo | null = null;
  private timer: CountdownTimer = new CountdownTimer((remainingMs: number) => {
    this.countdownText = formatCountdown(remainingMs);
    // Perbarui jam saat ini pada tick yang sama — nol biaya timer tambahan
    // (satu-satunya sumber tick adalah CountdownTimer hemat baterai).
    this.currentClock = PrayerViewModel.formatClock(new Date());
    if (remainingMs <= 0) {
      // Waktu sholat tiba -> hitung ulang target berikutnya.
      this.recomputeNextPrayer();
    }
  });
  private refreshTimerId: number = -1;

  /** Format HH:mm:ss dengan zero-padding (digit tetap agar tidak bergeser). */
  static formatClock(d: Date): string {
    const hh: string = d.getHours().toString().padStart(2, '0');
    const mm: string = d.getMinutes().toString().padStart(2, '0');
    const ss: string = d.getSeconds().toString().padStart(2, '0');
    return `${hh}:${mm}:${ss}`;
  }

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
        // Belum ada data apa pun untuk ditampilkan -> beri pesan error yang
        // jelas + tombol Refresh (desain awal: tidak ada jadwal default).
        this.loadState = LoadState.ERROR_API;
        this.errorMessage = 'Waktu muat habis. Tekan Refresh untuk mencari jadwal lagi.';
      } else {
        // Data cache sudah tampil — cukup beri catatan, JANGAN turunkan mutu
        // tampilan hanya karena pembaruan jaringan terlambat.
        this.errorMessage = 'Pembaruan jadwal lambat — data terakhir tetap ditampilkan.';
      }
    } finally {
      // ── JAMINAN FINAL: state TIDAK BOLEH LOADING lagi setelah bootstrap ──
      if (this.loadState === LoadState.LOADING) {
        this.loadState = this.schedule.length > 0 ? LoadState.READY : LoadState.ERROR_API;
        if (this.schedule.length === 0 && this.errorMessage.length === 0) {
          this.errorMessage = 'Gagal memuat jadwal. Tekan Refresh untuk mencoba lagi.';
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
      // Watch tetap berguna: LocationService akan memakai koordinat default
      // Jakarta, namun fetch TIDAK dijalankan saat permission jelas ditolak —
      // user melihat pesan + tombol Refresh untuk mencoba setelah mengaktifkan izin.
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
    //    wrapper 15s + fallback cache/default Jakarta) — dibatasi 12s di sini.
    try {
      const geo: GeoInfo = await this.withDeadline<GeoInfo>(LocationService.getGeoInfo(), 12000);
      this.geo = geo;
      this.cityName = geo.cityName;
    } catch (geoErr) {
      // Lokasi gagal total -> fetch tetap jalan dengan koordinat terakhir/
      // default yang tersimpan di LocationService (lihat getGeoInfo()).
      hilog.warn(DOMAIN, TAG, 'Geolocation unavailable; using last-known coords.');
    }

    // 3) AMBIL JADWAL: cache harian -> Aladhan via koordinat (PrayerApiService).
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
        // Cache hari ini (desain awal tidak lagi memakai negative-cache
        // default-jakarta; flag lama dari versi sebelumnya tetap aman
        // dibaca sebagai data biasa).
        this.loadState = LoadState.READY;
      }
      // Cache basi -> tetap tampilkan dulu; pipeline jaringan akan
      // menaikkannya ke READY/ERROR nanti (watch tidak pernah blank).
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'hydrateFromCache parse failed');
    }
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
  private async fetchScheduleAndRemind(forceRefresh: boolean = false): Promise<void> {
    // Sumber tunggal desain awal: Aladhan via koordinat GPS. Bila lokasi
    // belum tersedia (GPS gagal/telat), LocationService sudah menyediakan
    // fallback koordinat default Jakarta di dalam getGeoInfo().
    let geo: GeoInfo | null = this.geo;
    if (forceRefresh) {
      // REFRESH MANUAL (user mungkin baru berpindah tempat): ambil ulang
      // koordinat TERBARU dari GPS, jangan pakai hasil bootstrap lama.
      try {
        geo = await this.withDeadline<GeoInfo>(LocationService.getGeoInfo(), 12000);
        this.geo = geo;
        this.cityName = geo.cityName;
      } catch (geoErr) {
        hilog.warn(DOMAIN, TAG, 'Refresh re-locate failed; using last known coords.');
      }
    }

    const lat: number | undefined = geo !== null ? geo.latitude : undefined;
    const lon: number | undefined = geo !== null ? geo.longitude : undefined;
    const result: PrayerFetchResult =
      await PrayerApiService.getTodaysPrayerTimes(lat, lon, forceRefresh);

    if (result.schedule === null) {
      // Jaringan gagal & cache kosong — tampilkan pesan error; tombol Refresh
      // tetap tersedia untuk mencoba lagi dari nol (tanpa negative cache).
      hilog.error(DOMAIN, TAG, 'All sources failed: %{public}s', result.errorMessage);
      this.loadState = LoadState.ERROR_API;
      this.errorMessage = result.errorMessage.length > 0 ? result.errorMessage
        : 'Gagal memuat jadwal. Periksa koneksi lalu tekan Refresh.';
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

  /**
   * REFRESH MANUAL — tombol "Refresh" di UI.
   * Berjalan TANPA negative cache & TANPA deadline bootstrap yang ketat:
   *  1. Lewati cache harian sepenuhnya (forceRefresh=true).
   *  2. Ambil ulang koordinat GPS terbaru (user mungkin berpindah tempat).
   *  3. Fetch Aladhan -> persist -> jadwalkan ulang reminder.
   * Flag `isRefreshing` mencegah tap ganda; jam saat ini tetap jalan karena
   * CountdownTimer tidak pernah disetop selama proses ini.
   */
  async refresh(context?: common.UIAbilityContext): Promise<void> {
    if (this.isRefreshing) { return; }
    this.isRefreshing = true;
    // Bersihkan pesan error lama agar banner tidak membingungkan saat retry.
    this.errorMessage = '';
    try {
      // Bila permission belum pernah diminta (context tersedia & state awal),
      // minta lagi sekalian — dialog dibatasi 8s seperti di bootstrap.
      if (context !== undefined && this.loadState === LoadState.ERROR_NO_PERMISSION) {
        let granted: boolean = false;
        try {
          granted = await this.withDeadline<boolean>(
            PermissionService.requestLocationPermissions(context), 8000);
        } catch (permErr) {
          granted = false;
        }
        if (!granted) {
          this.errorMessage = 'Izin lokasi masih ditolak. Aktifkan lewat Settings > Apps > MySholat.';
          return;
        }
        this.loadState = LoadState.LOADING;
      }
      await this.fetchScheduleAndRemind(true);
    } finally {
      this.isRefreshing = false;
      // Jaminan: refresh tidak boleh meninggalkan layar loading kosong.
      if (this.loadState === LoadState.LOADING) {
        this.loadState = this.schedule.length > 0 ? LoadState.READY : LoadState.ERROR_API;
        if (this.errorMessage.length === 0 && this.schedule.length === 0) {
          this.errorMessage = 'Gagal memuat jadwal. Tekan Refresh untuk mencoba lagi.';
        }
      }
    }
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
