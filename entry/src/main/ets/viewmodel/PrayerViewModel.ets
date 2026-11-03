/**
 * PrayerViewModel.ets
 * -------------------
 * Orkestrator state halaman utama (pola MVVM ringan):
 *  onboarding permission -> lokasi -> API Aladhan -> jadwal + countdown
 *  -> jadwalkan ReminderAgent H-10 menit.
 * Semua error dikumpulkan ke field `errorMessage` agar UI bisa menampilkan
 * pesan yang jelas (izin ditolak / gagal memuat jadwal).
 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PermissionService } from '../services/PermissionService.ets';
import { LocationService } from '../services/LocationService.ets';
import { PrayerApiService } from '../services/PrayerApiService.ets';
import { ReminderService } from '../services/ReminderService.ets';
import { preference } from '../services/PreferenceService.ets';
import { GeoInfo, PrayerFetchResult, PrayerScheduleItem } from '../model/PrayerModels.ets';
import { CountdownTimer, formatCountdown } from './CountdownTimer.ets';
import { DEFAULT_CITY, PREF_KEY_DATE, PREF_KEY_SCHEDULE, REFRESH_INTERVAL_MS } from '../common/Constants.ets';

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

    // 1) ONBOARDING PERMISSION — minta izin lokasi saat pertama dibuka.
    // Bila konteks tak tersedia, anggap permission sudah pernah diminta/granted.
    const granted: boolean = context !== undefined
      ? await PermissionService.requestLocationPermissions(context)
      : true;
    if (!granted) {
      this.loadState = LoadState.ERROR_NO_PERMISSION;
      this.errorMessage = 'Izin lokasi ditolak. Aktifkan lewat Settings > Apps > MySholat agar jadwal sesuai kotamu.';
      // Tetap tampilkan jadwal cache/default Jakarta supaya watch berguna.
      await this.loadFromCacheOrEmpty();
      return;
    }

    // 1b) Izin notifikasi untuk reminder.
    await ReminderService.ensureNotificationEnabled();

    // 2) DETEKSI LOKASI (+ reverse geocoding nama kota).
    const geo: GeoInfo = await LocationService.getGeoInfo();
    this.geo = geo;
    this.cityName = geo.cityName;

    // 3) AMBIL JADWAL dari API Aladhan (method=20 Kemenag RI).
    await this.fetchScheduleAndRemind();

    // 4) Refresh berkala hemat baterai (30 mnt) selama foreground.
    this.startPeriodicRefresh();
  }

  /** Ambil jadwal + jadwalkan reminder H-10 menit. */
  private async fetchScheduleAndRemind(): Promise<void> {
    const geo: GeoInfo | null = this.geo;
    if (geo === null) { return; }

    // Orkestrator cache-first: MyQuran (cityId) -> Aladhan (lat/lon) -> stale cache.
    const cityId: string = await preference.loadSelectedCityId();
    const result: PrayerFetchResult =
      await PrayerApiService.getTodaysPrayerTimes(cityId, geo.latitude, geo.longitude);

    if (result.schedule === null) {
      // Tidak ada data sama sekali (jaringan gagal & cache kosong).
      hilog.error(DOMAIN, TAG, 'All sources failed: %{public}s', result.errorMessage);
      this.loadState = LoadState.ERROR_API;
      this.errorMessage = 'Gagal memuat jadwal. Periksa koneksi Bluetooth/Wi-Fi lalu coba lagi.';
      return;
    }

    // Selalu tampilkan data — fresh maupun stale — agar watch tetap berguna.
    this.schedule = result.schedule.toItems();
    if (result.isError) {
      // Data basi tersaji + banner peringatan (state ERROR_API memicu tombol retry).
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

  /** Deteksi pergantian hari: bila tanggal berubah, reset ke loading & fetch ulang. */
  async checkDayRollover(): Promise<void> {
    const cachedDate: string = (await preference.getString(PREF_KEY_DATE, '')) as string;
    if (cachedDate !== PrayerApiService.todayKey()) {
      hilog.info(DOMAIN, TAG, 'Day changed (%{public}s -> %{public}s), refetching.',
        cachedDate, PrayerApiService.todayKey());
      if (this.geo) {
        await this.fetchScheduleAndRemind();
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
    if (this.loadState === LoadState.READY && this.schedule.length > 0) {
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

  private async loadFromCacheOrEmpty(): Promise<void> {
    const raw: string = (await preference.getString(PREF_KEY_SCHEDULE, '')) as string;
    if (raw.length > 0) {
      this.schedule = JSON.parse(raw) as PrayerScheduleItem[];
      this.recomputeNextPrayer();
    }
  }
}
