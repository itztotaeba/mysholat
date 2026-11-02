/**
 * PrayerApiService.ets
 * --------------------
 * Mengakses API jadwal sholat Aladhan:
 *   https://api.aladhan.com/v1/timings?latitude={lat}&longitude={lon}&method=20
 * method=20 = Kemenag RI. Response di-parse ke PrayerScheduleItem[],
 * dengan cache lokal (Preferences) sebagai fallback bila jaringan gagal.
 */
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AladhanResponse, PrayerScheduleItem } from '../model/PrayerModels.ets';
import {
  ALADHAN_TIMINGS_URL, PREF_KEY_DATE, PREF_KEY_SCHEDULE, PrayerNames
} from '../common/Constants.ets';
import { preference } from './PreferenceService.ets';

const DOMAIN: number = 0x0000;
const TAG: string = 'MySholat|API';

export class PrayerApiService {
  /**
   * Ambil jadwal 5 waktu sholat hari ini untuk koordinat tertentu.
   * @throws Error bila request gagal DAN tidak ada cache -> UI menampilkan
   *         pesan "Gagal memuat jadwal".
   */
  static async fetchTodayTimings(lat: number, lon: number): Promise<PrayerScheduleItem[]> {
    const url: string = ALADHAN_TIMINGS_URL
      .replace('{lat}', lat.toFixed(4))
      .replace('{lon}', lon.toFixed(4));

    const httpRequest = http.createHttp();
    try {
      const response = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        readTimeout: 10000,
        connectTimeout: 10000
      });

      if (response.responseCode !== 200) {
        throw new Error(`HTTP ${response.responseCode}`);
      }

      // Parsing JSON eksplisit — hindari `any`, cast ke interface model.
      // Catatan arkts-no-structural-typing: hasil JSON.parse (Record<string,
      // Object>) di-cast langsung ke interface model aplikasi yang memang
      // mendeklarasikan field respons Aladhan — ini pola resmi ArkTS untuk
      // deserialisasi, BUKAN assignment antar-dua deklarasi berbeda.
      const raw: string = typeof response.result === 'string'
        ? response.result as string : String(response.result);
      const body: AladhanResponse = JSON.parse(raw) as AladhanResponse;
      if (!body || !body.data || !body.data.timings) {
        throw new Error('Invalid Aladhan payload');
      }

      const items: PrayerScheduleItem[] = PrayerApiService.buildSchedule(body);
      // Simpan cache + tanggalnya untuk fallback offline & deteksi ganti hari.
      const todayKey: string = PrayerApiService.todayKey();
      await preference.setString(PREF_KEY_DATE, todayKey);
      await preference.setString(PREF_KEY_SCHEDULE, JSON.stringify(items));
      return items;
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'fetchTimings failed: %{public}s', e.message ?? String(err));

      // FALLBACK: pakai cache jika tanggal cache masih hari ini.
      const cachedDate: string = (await preference.getString(PREF_KEY_DATE, '')) as string;
      const cachedRaw: string = (await preference.getString(PREF_KEY_SCHEDULE, '')) as string;
      if (cachedDate === PrayerApiService.todayKey() && cachedRaw.length > 0) {
        hilog.warn(DOMAIN, TAG, 'Serving cached schedule for today.');
        return JSON.parse(cachedRaw) as PrayerScheduleItem[];
      }
      // Tidak ada cache valid -> lempar error agar UI tampilkan pesan gagal.
      throw new Error('Gagal memuat jadwal');
    } finally {
      httpRequest.destroy(); // wajib: hindari kebocoran koneksi HTTP di watch
    }
  }

  /** Konversi response Aladhan -> daftar PrayerScheduleItem hari ini. */
  private static buildSchedule(body: AladhanResponse): PrayerScheduleItem[] {
    const t = body.data.timings;
    const pairs: string[][] = [
      [PrayerNames.SUBUH, 'Fajr', t.Fajr],
      [PrayerNames.DZUHUR, 'Dhuhr', t.Dhuhr],
      [PrayerNames.ASHAR, 'Asr', t.Asr],
      [PrayerNames.MAGHRIB, 'Maghrib', t.Maghrib],
      [PrayerNames.ISYA, 'Isha', t.Isha]
    ];

    const result: PrayerScheduleItem[] = [];
    for (let i = 0; i < pairs.length; i++) {
      const rawTime: string = pairs[i][2];               // contoh: "04:35 (+07)"
      const hhmm: string = PrayerApiService.cleanTime(rawTime); // "04:35"
      const ms: number = PrayerApiService.toTodayMs(hhmm);
      result.push(new PrayerScheduleItem(pairs[i][0], pairs[i][1], hhmm, ms));
    }
    return result;
  }

  /** Buang suffix zona waktu " (+07)" dari string waktu Aladhan. */
  private static cleanTime(raw: string): string {
    const idx: number = raw.indexOf(' ');
    return idx > 0 ? raw.substring(0, idx) : raw;
  }

  /** HH:mm -> timestamp ms pada tanggal hari ini (waktu lokal device). */
  private static toTodayMs(hhmm: string): number {
    const parts: string[] = hhmm.split(':');
    const d: Date = new Date();
    d.setHours(parseInt(parts[0], 10), parseInt(parts[1], 10), 0, 0);
    return d.getTime();
  }

  /** Kunci tanggal lokal "YYYY-MM-DD" untuk cek kesegaran cache. */
  static todayKey(): string {
    const d: Date = new Date();
    const m: string = (d.getMonth() + 1).toString().padStart(2, '0');
    const day: string = d.getDate().toString().padStart(2, '0');
    return `${d.getFullYear()}-${m}-${day}`;
  }
}
