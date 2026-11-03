/**
 * PrayerModels.ets
 * ----------------
 * Model data (strict typing, tanpa `any`) untuk response API Aladhan
 * dan struktur jadwal sholat yang dipakai UI.
 */

/* ==========================================================================
 * RESPONSE MODEL — MyQuran v2 (PRIMARY API, payload ringan & server ID)
 * GET https://api.myquran.com/v2/sholat/jadwal/{id_kota}/{yyyy-mm-dd}
 * ========================================================================== */
export interface MyQuranResponse {
  status: boolean;
  message: string;
  data: MyQuranData;
}

export interface MyQuranData {
  lokasi: string;
  tanggal: string;    // "YYYY-MM-DD"
  jadwal: MyQuranJadwal;
}

/**
 * Field jadwal MyQuran memakai penamaan lokal: subuh, dzuhur, ashar,
 * maghrib, isya (format "HH:mm" tanpa zona waktu — lebih ringan di-parse
 * daripada Aladhan yang bersuffix " (+07)").
 */
export interface MyQuranJadwal {
  imsak: string;
  subuh: string;
  dzuhur: string;
  ashar: string;
  maghrib: string;
  isya: string;
  terbit: string;
}

/* ==========================================================================
 * RESPONSE MODEL — Aladhan v1/timings (FALLBACK API, method=20 Kemenag RI)
 * ========================================================================== */
/** Response JSON API Aladhan /v1/timings (hanya field yang kita butuhkan). */
export interface AladhanResponse {
  code: number;
  status: string;
  data: AladhanData;
}

export interface AladhanData {
  timings: AladhanTimings;
  date: AladhanDate;
}

/** Format waktu dari Aladhan: "HH:mm (+07)" -> ambil 5 karakter pertama. */
export interface AladhanTimings {
  Fajr: string;
  Sunrise: string;
  Dhuhr: string;
  Asr: string;
  Maghrib: string;
  Isha: string;
}

export interface AladhanDate {
  readable: string;   // mis. "03-Nov-2026"
  timestamp: string;  // unix detik dalam bentuk string
  hijri: AladhanHijri;
}

export interface AladhanHijri {
  day: string;
  month: AladhanHijriMonth;
  year: string;
}

export interface AladhanHijriMonth {
  en: string;
}

/** Satu entri jadwal sholat untuk ditampilkan di List UI. */
export class PrayerScheduleItem {
  /** Nama lokal: Subuh / Dzuhur / Ashar / Maghrib / Isya */
  name: string;
  /** Key asli API: Fajr / Dhuhr / Asr / Maghrib / Isha */
  apiName: string;
  /** Waktu dalam format HH:mm (sudah dibersihkan dari zona "+07") */
  time: string;
  /** Timestamp ms hari ini untuk perhitungan countdown */
  timeMs: number;
  /** true jika waktu sholat sudah lewat */
  isPassed: boolean;
  /** true jika ini sholat berikutnya (diberi aksen warna mencolok) */
  isNext: boolean;

  constructor(name: string, apiName: string, time: string, timeMs: number) {
    this.name = name;
    this.apiName = apiName;
    this.time = time;
    this.timeMs = timeMs;
    this.isPassed = false;
    this.isNext = false;
  }
}

/**
 * Jadwal HARIAN yang sudah NORMALISASI — bentuk kanonik yang sama persis
 * baik bila sumbernya MyQuran maupun Aladhan. Inilah struktur yang disimpan
 * ke Preferences sebagai `cachedSchedule` (stringified JSON), sehingga layer
 * cache tidak perlu tahu API mana yang menghasilkan data.
 *
 * Catatan ArkTS: pakai `class` (bukan interface) agar instance bisa dibuat
 * via constructor — menghindari arkts-no-untyped-obj-literals & memudahkan
 * deserialisasi JSON.parse(...) as NormalizedDailySchedule (pola resmi ArkTS).
 */
export class NormalizedDailySchedule {
  /** Tanggal jadwal "YYYY-MM-DD" (sanity-check terhadap lastFetchDate). */
  date: string;
  subuh: string;      // "HH:mm"
  dzuhur: string;     // "HH:mm"
  ashar: string;      // "HH:mm"
  maghrib: string;    // "HH:mm"
  isya: string;       // "HH:mm"
  /** Sumber data — informatif untuk log/debug ('myquran' | 'aladhan'). */
  source: string;

  constructor(date: string, subuh: string, dzuhur: string, ashar: string,
    maghrib: string, isya: string, source: string) {
    this.date = date;
    this.subuh = subuh;
    this.dzuhur = dzuhur;
    this.ashar = ashar;
    this.maghrib = maghrib;
    this.isya = isya;
    this.source = source;
  }

  /**
   * Konversi jadwal ternormalisasi -> daftar PrayerScheduleItem untuk UI.
   * timeMs dihitung ulang saat runtime (jam lokal device) sehingga hasil
   * yang berasal dari cache lama pun tetap valid untuk countdown hari ini.
   */
  toItems(): PrayerScheduleItem[] {
    const defs: string[][] = [
      ['Subuh', 'Fajr', this.subuh],
      ['Dzuhur', 'Dhuhr', this.dzuhur],
      ['Ashar', 'Asr', this.ashar],
      ['Maghrib', 'Maghrib', this.maghrib],
      ['Isya', 'Isha', this.isya]
    ];
    const items: PrayerScheduleItem[] = [];
    for (let i = 0; i < defs.length; i++) {
      items.push(new PrayerScheduleItem(defs[i][0], defs[i][1], defs[i][2],
        NormalizedDailySchedule.toTodayMs(defs[i][2])));
    }
    return items;
  }

  /** HH:mm -> timestamp ms pada tanggal hari ini (waktu lokal device). */
  static toTodayMs(hhmm: string): number {
    const parts: string[] = hhmm.split(':');
    const d: Date = new Date();
    d.setHours(parseInt(parts[0], 10), parseInt(parts[1], 10), 0, 0);
    return d.getTime();
  }
}

/**
 * Hasil orchestrator getTodaysPrayerTimes() — selalu mengembalikan data
 * (fresh / cache sehat / cache basi) plus flag error agar UI bisa menampilkan
 * banner peringatan tanpa mengorbankan kegunaan jam tangan.
 */
export class PrayerFetchResult {
  schedule: NormalizedDailySchedule | null;
  /** true bila seluruh upaya jaringan gagal (data yang ada = stale cache). */
  isError: boolean;
  errorMessage: string;

  constructor(schedule: NormalizedDailySchedule | null, isError: boolean, errorMessage: string) {
    this.schedule = schedule;
    this.isError = isError;
    this.errorMessage = errorMessage;
  }
}

/** Hasil reverse geocoding sederhana (nama kota/regency). */
export class GeoInfo {
  latitude: number;
  longitude: number;
  cityName: string;

  constructor(latitude: number, longitude: number, cityName: string) {
    this.latitude = latitude;
    this.longitude = longitude;
    this.cityName = cityName;
  }
}

/**
 * Kelas pembungkus hasil getCurrentLocation milik aplikasi sendiri.
 *
 * PENTING (arkts-no-structural-typing): ArkTS melarang meng-assign objek
 * dari modul SDK lain (geoLocationManager.Location) ke tipe/deklarasi lokal
 * meskipun strukturnya identik — hanya class yang DEKlarasinya sama persis
 * yang boleh saling di-assign. Karena itu hasil lokasi SDK TIDAK PERNAH
 * ditipkan sebagai variabel lokal bertipe custom; field `latitude` &
 * `longitude` langsung dibaca dan dibungkus di sini lewat constructor.
 */
export class PrayerPosition {
  latitude: number;
  longitude: number;

  constructor(latitude: number, longitude: number) {
    this.latitude = latitude;
    this.longitude = longitude;
  }
}
