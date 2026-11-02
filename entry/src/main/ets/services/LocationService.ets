/**
 * LocationService.ets
 * -------------------
 * Deteksi lokasi menggunakan @ohos.geoLocationManager (HarmonyOS Location Kit):
 *  - ONE_SINGLE fix location (sekali ambil, hemat baterai — bukan continuous).
 *  - Reverse geocoding -> nama kota (mis. "Jakarta Selatan").
 *  - Fallback: cache koordinat terakhir di Preferences, lalu default Jakarta.
 */
import { geoLocationManager } from '@kit.LocationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { preference } from './PreferenceService.ets';
import { GeoInfo } from '../model/PrayerModels.ets';

/** Helper concrete-class agar tidak melanggar arkts-no-untyped-obj-literals. */
class GeoInfoImpl {
  latitude: number = 0;
  longitude: number = 0;
  cityName: string = '';
}
import { DEFAULT_CITY, DEFAULT_LAT, DEFAULT_LON, PREF_KEY_CITY, PREF_KEY_LAT, PREF_KEY_LON } from '../common/Constants.ets';

const DOMAIN: number = 0x0000;
const TAG: string = 'MySholat|Location';

export class LocationService {
  /**
   * Ambil lokasi saat ini. Menggunakan skema ONE_SINGLE sehingga radio GPS
   * hanya aktif sebentar (ramah baterai smartwatch).
   */
  static async getCurrentLocation(): Promise<GeoInfo> {
    try {
      // Guard: jika Location Service mati, getCurrentLocation akan melempar 3301200 —
      // langsung fallback ke cache/default agar tidak membuang waktu tunggu.
      if (!geoLocationManager.isLocationEnabled()) {
        hilog.warn(DOMAIN, TAG, 'Location service disabled, using cache/default.');
        return LocationService.getCachedOrDefault();
      }
      const request: geoLocationManager.SingleLocationRequest = {
        locatingTimeoutMs: 10000,     // milidetik (API baru; dulu `locatingTimeout` dalam detik)
        // Enum LocationAccuracy tidak tersedia di beberapa versi SDK wearable,
        // jadi gunakan angka literal (2 = accuracy tinggi / navigation-grade).
        locationAccuracy: 2
      };
      const location: geoLocationManager.LocationResult = await geoLocationManager.getCurrentLocation(request);
      hilog.info(DOMAIN, TAG, 'Got location: %{public}f, %{public}f', location.latitude, location.longitude);

      // Simpan sebagai cache untuk mode offline berikutnya.
      await preference.setNumber(PREF_KEY_LAT, location.latitude);
      await preference.setNumber(PREF_KEY_LON, location.longitude);

      const cityName: string = await LocationService.reverseGeocode(location.latitude, location.longitude);
      const info: GeoInfoImpl = new GeoInfoImpl();
      info.latitude = location.latitude;
      info.longitude = location.longitude;
      info.cityName = cityName;
      return info;
    } catch (err) {
      const e = err as BusinessError;
      // 3301100: lokasi timeout / 3301200: permission belum granted
      hilog.error(DOMAIN, TAG, 'getCurrentLocation failed: code=%{public}d msg=%{public}s', e.code, e.message);
      return LocationService.getCachedOrDefault();
    }
  }

  /** Reverse geocoding -> "Kota / Kabupaten". Gagal -> pakai cache/default. */
  private static async reverseGeocode(lat: number, lon: number): Promise<string> {
    try {
      // ReverseGeoCodeRequest memakai field latitude/longitude langsung
      // (bukan objek `position`, dan tipe `Position` memang tidak diekspor SDK).
      const request: geoLocationManager.ReverseGeoCodeRequest = {
        latitude: lat,
        longitude: lon,
        locale: 'id',
        maxItems: 1
      };
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
  private static async getCachedOrDefault(): Promise<GeoInfo> {
    const lat: number = (await preference.getNumber(PREF_KEY_LAT, DEFAULT_LAT)) as number;
    const lon: number = (await preference.getNumber(PREF_KEY_LON, DEFAULT_LON)) as number;
    const city: string = (await preference.getString(PREF_KEY_CITY, DEFAULT_CITY)) as string;
    const info: GeoInfoImpl = new GeoInfoImpl();
    info.latitude = lat;
    info.longitude = lon;
    info.cityName = city;
    return info;
  }
}
