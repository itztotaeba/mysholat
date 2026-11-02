/**
 * PrayerModels.ets
 * ----------------
 * Model data (strict typing, tanpa `any`) untuk response API Aladhan
 * dan struktur jadwal sholat yang dipakai UI.
 */

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
