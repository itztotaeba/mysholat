/**
 * LocationService.ets
 * -------------------
 * Deteksi lokasi menggunakan @kit.LocationKit (HarmonyOS Location Kit):
 *  - getCurrentLocation ONE_SINGLE (sekali ambil, hemat baterai — bukan continuous).
 *  - Reverse geocoding -> nama kota (mis. "Jakarta Selatan").
 *  - Fallback: cache koordinat terakhir di Preferences, lalu default Jakarta.
 *
 * CATATAN KOMPILASI ARKTS (pengalaman error yang sudah diperbaiki):
 *  1. arkts-no-misplaced-imports : semua import wajib di paling atas file.
 *  2. SingleLocationRequest      : field WAJIB `locatingPriority`; timeout memakai
 *     `locatingTimeoutMs` (milidetik). `locationAccuracy` TIDAK ada di tipe ini.
 *  3. Tipe hasil                 : getCurrentLocation mengembalikan
 *     `geoLocationManager.Location`. `LocationResult` / `Position` TIDAK diekspor SDK.
 *  4. arkts-no-structural-typing : objek hasil SDK TIDAK BOLEH di-assign ke class/
 *     interface lokal meskipun strukturnya sama. Variabel penampung selalu diberi
 *     tipe eksplisit dari namespace SDK (`geoLocationManager.Location` /
 *     `geoLocationManager.GeoAddress[]`), baru nilainya dibungkus via constructor
 *     PrayerPosition/GeoInfo milik aplikasi sendiri.
 *  5. getCurrentLocation dipanggil SATU KALI per fix (hemat baterai watch).
 */
import { geoLocationManager } from '@kit.LocationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { preference } from './PreferenceService.ets';
import { GeoInfo, PrayerPosition } from '../model/PrayerModels.ets';
import {
  DEFAULT_CITY, DEFAULT_LAT, DEFAULT_LON,
  PREF_KEY_CITY, PREF_KEY_LAT, PREF_KEY_LON
} from '../common/Constants.ets';

const DOMAIN: number = 0x0000;
const TAG: string = 'MySholat|Location';

export class LocationService {
  /**
   * Ambil satu fix lokasi saat ini (one-shot, radio GPS aktif sebentar saja).
   * Hasil SDK ditampung di variabel BERTIPE EKSPLISIT `geoLocationManager.Location`
   * (tipe resmi API), lalu field latitude/longitude dibungkus lewat constructor
   * PrayerPosition milik aplikasi — tidak pernah ada assignment objek SDK ke
   * class/interface lokal mirip-struktur, sehingga aman dari arkts-no-structural-typing.
   */
  static async getCurrentLocation(): Promise<PrayerPosition> {
    try {
      // Guard: jika Location Service mati, getCurrentLocation melempar 3301200 —
      // langsung pakai cache/default agar tidak membuang waktu tunggu & baterai.
      if (!geoLocationManager.isLocationEnabled()) {
        hilog.warn(DOMAIN, TAG, 'Location service disabled, using cache/default.');
        return LocationService.getCachedPosition();
      }

      const request: geoLocationManager.SingleLocationRequest = {
        // locatingPriority adalah field REQUIRED pada SingleLocationRequest.
        locatingPriority: geoLocationManager.LocatingPriority.PRIORITY_ACCURACY,
        locatingTimeoutMs: 10000 // milidetik (bukan `locatingTimeout` detik)
      };

      // One-shot: panggil SEKALI. Variabel penampung DIBERI TIPE EKSPLISIT
      // `geoLocationManager.Location` (tipe hasil resmi API). Menampung tanpa
      // anotasi tipe memicu arkts-no-structural-typing karena compiler mencoba
      // mencocokkan objek SDK ke deklarasi lokal yang "mirip strukturnya".
      const sdkLoc: geoLocationManager.Location =
        await geoLocationManager.getCurrentLocation(request);
      const lat: number = sdkLoc.latitude;
      const lon: number = sdkLoc.longitude;
      await preference.setNumber(PREF_KEY_LAT, lat);
      await preference.setNumber(PREF_KEY_LON, lon);
      hilog.info(DOMAIN, TAG, 'Got location: %{public}f, %{public}f', lat, lon);
      return new PrayerPosition(lat, lon);
    } catch (err) {
      const e = err as BusinessError;
      // 3301100: timeout locating | 3301200: permission/service bermasalah
      hilog.error(DOMAIN, TAG, 'getCurrentLocation failed: code=%{public}d msg=%{public}s',
        e.code, e.message);
      return LocationService.getCachedPosition();
    }
  }

  /** Info lengkap untuk UI: posisi + nama kota (reverse geocode, with fallback). */
  static async getGeoInfo(): Promise<GeoInfo> {
    const pos: PrayerPosition = await LocationService.getCurrentLocation();
    const city: string = await LocationService.reverseGeocode(pos.latitude, pos.longitude);
    return new GeoInfo(pos.latitude, pos.longitude, city);
  }

  /** Reverse geocoding -> "Kota / Kabupaten". Gagal -> pakai cache/default. */
  private static async reverseGeocode(lat: number, lon: number): Promise<string> {
    try {
      // ReverseGeoCodeRequest memakai field latitude/longitude LANGSUNG
      // (bukan objek `position`; tipe `Position` memang tidak diekspor SDK).
      const request: geoLocationManager.ReverseGeoCodeRequest = {
        latitude: lat,
        longitude: lon,
        locale: 'id',
        maxItems: 1
      };
      // Array elemen SDK hanya dibaca per-index dan field-nya diakses inline;
      // tidak ada assignment lintas-tipe struktural di sini.
      const list: geoLocationManager.GeoAddress[] =
        await geoLocationManager.getAddressesFromLocation(request);
      if (list.length > 0) {
        const addr: geoLocationManager.GeoAddress = list[0];
        const city: string = addr.locality ?? addr.subLocality ?? addr.administrativeArea ?? '';
        if (city.length > 0) {
          await preference.setString(PREF_KEY_CITY, city);
          return city;
        }
      }
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'reverseGeocode failed: %{public}s', e.message);
    }
    const cached: string = (await preference.getString(PREF_KEY_CITY, '')) as string;
    return cached.length > 0 ? cached : DEFAULT_CITY;
  }

  /** Fallback offline: koordinat terakhir yang disimpan, atau default Jakarta. */
  private static async getCachedPosition(): Promise<PrayerPosition> {
    const lat: number = (await preference.getNumber(PREF_KEY_LAT, DEFAULT_LAT)) as number;
    const lon: number = (await preference.getNumber(PREF_KEY_LON, DEFAULT_LON)) as number;
    return new PrayerPosition(lat, lon);
  }
}
