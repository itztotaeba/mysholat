/**
 * PrayerApiService.ets — Data-fetching layer untuk wearable
 * ---------------------------------------------------------
 * LOGIKA PENGAMBILAN JADWAL KEMBALI KE DESAIN AWAL (permintaan user):
 *   - SATU-SATUNYA sumber jaringan = Aladhan API (gratis & andal):
 *       https://api.aladhan.com/v1/timings?latitude={lat}&longitude={lon}&method=20
 *     (method=20 = jadwal Kemenag RI).
 *   - MyQuran DIHAPUS dari jalur utama: dalam pengujian live API tersebut
 *     sering membalas HTTP 200 + {"status":false,"message":"Data not found"}
 *     untuk tanggal hari ini, sehingga setiap sesi membuka aplikasi selalu
 *     berujung pada rantai fallback lambat + negative caching yang membuat
 *     UI tampak "loading terus" dan tombol "Coba Lagi" terasa mati.
 *   - CACHE HARIAN @ohos.data.preferences dipertahankan:
 *       lastFetchDate == hari ini  -> return cache instan (0ms jaringan).
 *       forceRefresh (tombol Refresh) -> SELALU lewati cache & ambil ulang
 *       dari jaringan (penting saat user berpindah kota/tempat).
 *   - Timeout jaringan tetap ketat (HTTP_*_TIMEOUT_MS di Constants) agar
 *     request tidak menggantung pada koneksi relay watch yang buruk.
 *   - Total failure -> stale cache (bila ada) + error flag; TIDAK ada
 *     negative-caching jadwal default lagi supaya "Coba Lagi" benar-benar
 *     mengulang pencarian dari awal.
 */
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  AladhanResponse, NormalizedDailySchedule, PrayerFetchResult
} from '../model/PrayerModels.ets';
import {
  ALADHAN_TIMINGS_URL, HTTP_CONNECT_TIMEOUT_MS, HTTP_READ_TIMEOUT_MS
} from '../common/Constants.ets';
import { preference } from './PreferenceService.ets';

const DOMAIN: number = 0x0000;
const TAG: string = 'MySholat|API';

export class PrayerApiService {
  /* ======================================================================
   * ORKESTRATOR UTAMA — panggil ini dari ViewModel.
   * ====================================================================== */

  /**
   * a. forceRefresh=false & lastFetchDate == hari ini -> return cache instan.
   * b. forceRefresh=true (tombol Refresh) atau cache basi -> fetch Aladhan
   *    dengan koordinat TERBARU (user mungkin baru pindah tempat).
   * c. Sukses -> simpan cachedSchedule + lastFetchDate ke Preferences.
   * d. Gagal  -> stale cache (bila ada) + isError=true; cache TIDAK ditimpa
   *    jadwal default, jadi retry berikutnya tetap sungguh-sungguh ke jaringan.
   */
  static async getTodaysPrayerTimes(lat?: number, lon?: number,
    forceRefresh: boolean = false): Promise<PrayerFetchResult> {
    const today: string = PrayerApiService.todayKey();

    // ── (a) CACHE HARIAN ──────────────────────────────────────────────────
    // Dilewati sepenuhnya saat forceRefresh — inilah bedanya dengan bug lama
    // di mana "Coba Lagi" membentur negative cache dan tampak tidak mencari.
    if (!forceRefresh) {
      const lastFetchDate: string = await preference.loadLastFetchDate();
      const cachedRaw: string = await preference.loadCachedSchedule();
      if (lastFetchDate === today && cachedRaw.length > 0) {
        try {
          const cached: NormalizedDailySchedule = JSON.parse(cachedRaw) as NormalizedDailySchedule;
          hilog.info(DOMAIN, TAG, 'Cache hit (%{public}s) — 0ms network.', today);
          return new PrayerFetchResult(cached, false, '');
        } catch (parseErr) {
          // Cache korup — abaikan, lanjut fetch jaringan.
          hilog.warn(DOMAIN, TAG, 'Corrupt cache, refetching.');
        }
      }
    }

    // ── (b) FETCH ALADHAN (sumber tunggal, desain awal) ───────────────────
    if (lat !== undefined && lon !== undefined) {
      try {
        const sched: NormalizedDailySchedule =
          await PrayerApiService.getPrayerTimesByCoords(lat, lon, today);
        // (c) Persist hasil segar -> cachedSchedule + lastFetchDate.
        await PrayerApiService.persist(sched, today);
        return new PrayerFetchResult(sched, false, '');
      } catch (e) {
        const err = e as Error;
        hilog.error(DOMAIN, TAG, 'Aladhan fetch failed: %{public}s', err.message);
      }
    }

    // ── (d) TOTAL FAILURE ─────────────────────────────────────────────────
    const cachedRaw2: string = await preference.loadCachedSchedule();
    if (cachedRaw2.length > 0) {
      try {
        const stale: NormalizedDailySchedule = JSON.parse(cachedRaw2) as NormalizedDailySchedule;
        // Tampilkan data tersimpan terakhir TANPA menimpanya, agar "Coba
        // Lagi"/buka berikutnya masih benar-benar menyentuh jaringan.
        return new PrayerFetchResult(stale, true,
          'Gagal memuat jadwal — menampilkan data tersimpan sebelumnya.');
      } catch (staleErr) {
        hilog.warn(DOMAIN, TAG, 'Stale cache unreadable.');
      }
    }
    return new PrayerFetchResult(null, true,
      'Gagal memuat jadwal. Periksa koneksi lalu tekan Refresh.');
  }

  /* ======================================================================
   * FETCHER — Aladhan API (method=20 Kemenag RI)
   * ====================================================================== */
  static async getPrayerTimesByCoords(lat: number, lon: number, dateStr: string): Promise<NormalizedDailySchedule> {
    const url: string = ALADHAN_TIMINGS_URL
      .replace('{lat}', lat.toFixed(4))
      .replace('{lon}', lon.toFixed(4));

    const raw: string = await PrayerApiService.httpGet(url);
    const body: AladhanResponse = JSON.parse(raw) as AladhanResponse;
    if (!body || !body.data || !body.data.timings) {
      throw new Error('Invalid Aladhan payload');
    }

    const t = body.data.timings;
    // Format Aladhan: "04:35 (+07)" -> potong suffix zona waktu.
    return new NormalizedDailySchedule(dateStr,
      PrayerApiService.cleanTime(t.Fajr),
      PrayerApiService.cleanTime(t.Dhuhr),
      PrayerApiService.cleanTime(t.Asr),
      PrayerApiService.cleanTime(t.Maghrib),
      PrayerApiService.cleanTime(t.Isha),
      'aladhan');
  }

  /* ======================================================================
   * INTERNAL HELPERS
   * ====================================================================== */

  /**
   * GET dengan TIMEOUT KETAT (connect/read = HTTP_*_TIMEOUT_MS, lihat
   * Constants.ets). Di wearable, radio sering tertidur atau koneksi relay HP
   * lambat; tanpa batas ini promise bisa menggantung dan menahan CPU/wakelock
   * => baterai terkuras & UI mentok loading. httpRequest.destroy() wajib
   * dipanggil untuk mencegah kebocoran socket.
   */
  private static async httpGet(url: string): Promise<string> {
    const httpRequest = http.createHttp();
    try {
      const response = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: HTTP_CONNECT_TIMEOUT_MS,
        readTimeout: HTTP_READ_TIMEOUT_MS
      });
      if (response.responseCode !== 200) {
        throw new Error(`HTTP ${response.responseCode}`);
      }
      return typeof response.result === 'string' ? response.result as string : String(response.result);
    } finally {
      httpRequest.destroy();
    }
  }

  /** (d) Persist hasil sukses -> cachedSchedule + lastFetchDate. */
  private static async persist(sched: NormalizedDailySchedule, dateStr: string): Promise<void> {
    await preference.saveCachedSchedule(JSON.stringify(sched));
    await preference.saveLastFetchDate(dateStr);
  }

  /** Buang suffix zona waktu " (+07)" dari string waktu Aladhan. */
  private static cleanTime(raw: string): string {
    const idx: number = raw.indexOf(' ');
    return idx > 0 ? raw.substring(0, idx) : raw;
  }

  /** Kunci tanggal lokal "YYYY-MM-DD" untuk cek kesegaran cache harian. */
  static todayKey(): string {
    const d: Date = new Date();
    const m: string = (d.getMonth() + 1).toString().padStart(2, '0');
    const day: string = d.getDate().toString().padStart(2, '0');
    return `${d.getFullYear()}-${m}-${day}`;
  }
}
