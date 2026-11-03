/**
 * PrayerApiService.ets — Data-fetching layer yang cepat & tangguh untuk wearable
 * ---------------------------------------------------------------------------
 * Strategi bertingkat (fast -> resilient):
 *   1. CACHE HARIAN agresif (@ohos.data.preferences): bila lastFetchDate == hari
 *      ini, jadwal dikembalikan SEKETIKA (0ms latency, 0 byte jaringan).
 *   2. PRIMARY API  : MyQuran v2  (server Indonesia, payload kecil)
 *        https://api.myquran.com/v2/sholat/jadwal/{id_kota}/{yyyy-mm-dd}
 *   3. FALLBACK API : Aladhan v1/timings method=20 (Kemenag RI) via koordinat.
 *   4. Timeout ketat connectTimeout/readTimeout = 5000ms — koneksi BT-relay
 *      watch yang lambat TIDAK boleh membuat request menggantung.
 *   5. Total failure -> kembalikan stale cache (watch tetap menampilkan
 *      sesuatu) disertai error flag di PrayerFetchResult.
 */
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  AladhanResponse, MyQuranResponse, NormalizedDailySchedule, PrayerFetchResult
} from '../model/PrayerModels.ets';
import {
  MYQURAN_JADWAL_URL, ALADHAN_TIMINGS_URL,
  HTTP_CONNECT_TIMEOUT_MS, HTTP_READ_TIMEOUT_MS
} from '../common/Constants.ets';
import { preference } from './PreferenceService.ets';

const DOMAIN: number = 0x0000;
const TAG: string = 'MySholat|API';

export class PrayerApiService {
  /* ======================================================================
   * ORKESTRATOR UTAMA — panggil ini dari ViewModel.
   * ====================================================================== */

  /**
   * a. Cache-first: lastFetchDate == dateStr -> return instan tanpa jaringan.
   * b. cityId tersedia -> coba MyQuran (cepat, ringan).
   * c. MyQuran gagal / cityId kosong -> fallback Aladhan via lat/lon.
   * d. Sukses -> simpan cachedSchedule + lastFetchDate ke Preferences.
   * e. Semua gagal -> stale cache (bila ada) + isError=true.
   */
  static async getTodaysPrayerTimes(cityId?: string, lat?: number, lon?: number): Promise<PrayerFetchResult> {
    const today: string = PrayerApiService.todayKey();

    // ── (a) AGGRESSIVE DAILY CACHE ────────────────────────────────────────
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

    // ── (b) PRIMARY: MyQuran ──────────────────────────────────────────────
    let primaryErr: string = '';
    if (cityId !== undefined && cityId.length > 0) {
      try {
        const sched: NormalizedDailySchedule = await PrayerApiService.getPrayerTimes(cityId, today);
        await PrayerApiService.persist(sched, today);
        return new PrayerFetchResult(sched, false, '');
      } catch (e1) {
        const err1 = e1 as Error;
        primaryErr = err1.message;
        hilog.warn(DOMAIN, TAG, 'MyQuran failed (%{public}s), falling back to Aladhan.', primaryErr);
      }
    } else {
      primaryErr = 'cityId tidak diset';
    }

    // ── (c) FALLBACK: Aladhan ─────────────────────────────────────────────
    if (lat !== undefined && lon !== undefined) {
      try {
        const sched2: NormalizedDailySchedule =
          await PrayerApiService.getPrayerTimesByCoords(lat, lon, today);
        await PrayerApiService.persist(sched2, today);
        return new PrayerFetchResult(sched2, false, '');
      } catch (e2) {
        const err2 = e2 as Error;
        hilog.error(DOMAIN, TAG, 'Aladhan fallback failed: %{public}s', err2.message);
      }
    }

    // ── (e) TOTAL FAILURE: sajikan stale cache agar watch tetap berguna ──
    if (cachedRaw.length > 0) {
      try {
        const stale: NormalizedDailySchedule = JSON.parse(cachedRaw) as NormalizedDailySchedule;
        return new PrayerFetchResult(stale, true,
          'Gagal memuat jadwal — menampilkan data tersimpan sebelumnya.');
      } catch (staleErr) {
        // Stale cache pun tak terbaca — jatuh ke hasil null di bawah.
      }
    }
    return new PrayerFetchResult(null, true, 'Gagal memuat jadwal');
  }

  /* ======================================================================
   * FETCHER PRIMER — MyQuran API (payload ~0.5KB, sangat ringan utk watch)
   * ====================================================================== */
  static async getPrayerTimes(cityId: string, dateStr: string): Promise<NormalizedDailySchedule> {
    const url: string = MYQURAN_JADWAL_URL
      .replace('{cityId}', encodeURIComponent(cityId))
      .replace('{date}', dateStr);

    const raw: string = await PrayerApiService.httpGet(url);
    // Deserialisasi resmi ArkTS: JSON.parse(...) as <interface model>.
    const body: MyQuranResponse = JSON.parse(raw) as MyQuranResponse;

    // Validasi struktural eksplisit — API bisa balas 200 dengan status=false.
    if (!body || !body.status || !body.data || !body.data.jadwal) {
      throw new Error('Invalid MyQuran payload');
    }
    const j = body.data.jadwal;
    if (j.subuh.length < 5 || j.dzuhur.length < 5 || j.ashar.length < 5 ||
      j.maghrib.length < 5 || j.isya.length < 5) {
      throw new Error('Incomplete MyQuran schedule');
    }
    // Waktu MyQuran sudah "HH:mm" murni — tinggal dinormalisasi.
    return new NormalizedDailySchedule(dateStr, j.subuh, j.dzuhur, j.ashar,
      j.maghrib, j.isya, 'myquran');
  }

  /* ======================================================================
   * FETCHER FALLBACK — Aladhan API (method=20 Kemenag RI)
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
   * GET dengan TIMEOUT KETAT (5s/5s). Di wearable, radio sering tertidur atau
   * koneksi relay HP lambat; tanpa batas ini promise bisa menggantung dan
   * menahan CPU/wakelock => baterai terkuras. httpRequest.destroy() wajib
   * dipanggil untuk mencegah kebocoran socket.
   */
  private static async httpGet(url: string): Promise<string> {
    const httpRequest = http.createHttp();
    try {
      const response = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: HTTP_CONNECT_TIMEOUT_MS, // 5000ms
        readTimeout: HTTP_READ_TIMEOUT_MS        // 5000ms
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
