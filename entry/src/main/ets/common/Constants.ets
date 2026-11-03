/**
 * Constants.ets
 * -------------
 * Pusat konstanta aplikasi "Pengingat Sholat" (Huawei Watch 5 / wearable).
 * Mengandung: endpoint API Aladhan, daftar waktu sholat, warna tema,
 * dan konstanta reminderAgentManager.
 */

/**
 * PRIMARY API — MyQuran (server Indonesia, payload kecil & responsif untuk watch).
 * Format: https://api.myquran.com/v2/sholat/jadwal/{id_kota}/{yyyy-mm-dd}
 */
export const MYQURAN_JADWAL_URL: string =
  'https://api.myquran.com/v2/sholat/jadwal/{cityId}/{date}';

/** City ID default MyQuran untuk Jakarta (dipakai bila cityId belum diset user). */
export const DEFAULT_CITY_ID: string = 'jakarta';

/** FALLBACK API — Aladhan. method=20 -> Kementerian Agama RI. */
export const ALADHAN_TIMINGS_URL: string =
  'https://api.aladhan.com/v1/timings?latitude={lat}&longitude={lon}&method=20';

/**
 * Timeout jaringan ketat (ms) untuk koneksi Bluetooth-relay smartwatch yang
 * lambat — mencegah request menggantung & baterai terkuras.
 */
export const HTTP_CONNECT_TIMEOUT_MS: number = 5000;
export const HTTP_READ_TIMEOUT_MS: number = 5000;

/** Interval refresh lokasi/jadwal saat aplikasi berada di foreground (30 menit).
 *  Nilai besar sengaja dipilih agar hemat baterai smartwatch. */
export const REFRESH_INTERVAL_MS: number = 30 * 60 * 1000;

/** Pengingat dikirim 10 menit sebelum waktu sholat. */
export const REMINDER_BEFORE_MINUTES: number = 10;

/** ID basis untuk trigger reminderAgent (agar tidak bentrok dengan trigger lain). */
export const REMINDER_BASE_ID: number = 8020;

/** Kunci penyimpanan Preferensi (lokal cache koordinat & jadwal). */
export const PREF_STORE_NAME: string = 'mysholat_prefs';
export const PREF_KEY_LAT: string = 'last_lat';
export const PREF_KEY_LON: string = 'last_lon';
export const PREF_KEY_CITY: string = 'last_city';
export const PREF_KEY_DATE: string = 'last_date';           // alias lastFetchDate
export const PREF_KEY_SCHEDULE: string = 'last_schedule';   // cachedSchedule (JSON string)
/** City ID MyQuran pilihan user (mis. 'bandung'); default DEFAULT_CITY_ID bila kosong. */
export const PREF_KEY_CITY_ID: string = 'selected_city_id';

/** Nama kota default bila reverse geocoding gagal / offline. */
export const DEFAULT_CITY: string = 'Jakarta Selatan';
export const DEFAULT_LAT: number = -6.2175;
export const DEFAULT_LON: number = 106.8061;

/** Label 5 waktu sholat dalam Bahasa Indonesia. */
export class PrayerNames {
  static readonly SUBUH: string = 'Subuh';
  static readonly DZUHUR: string = 'Dzuhur';
  static readonly ASHAR: string = 'Ashar';
  static readonly MAGHRIB: string = 'Maghrib';
  static readonly ISYA: string = 'Isya';
}

/** Warna tema (kontras tinggi, cocok untuk layar bulat AMOLED watch). */
export class AppColors {
  static readonly BG: string = '#0B1220';           // latar gelap
  static readonly CARD: string = '#151E2E';         // kartu
  static readonly ACCENT: string = '#22D3A7';       // hijau toska - sholat berikutnya
  static readonly TEXT_PRIMARY: string = '#FFFFFF';
  static readonly TEXT_SECONDARY: string = '#9AA7BD';
  static readonly DANGER: string = '#FF6B6B';       // pesan error
  static readonly PASSED: string = '#4A5568';       // waktu yang sudah lewat
  static readonly BORDER_DARK_BLUE: string = '#1E40AF'; // border kartu jadwal (biru tua)
}
