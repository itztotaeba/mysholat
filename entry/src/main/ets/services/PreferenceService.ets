/**
 * PreferenceService.ets
 * ---------------------
 * Pembungkus @ohos.data.preferences untuk cache lokal:
 * koordinat terakhir, nama kota, dan jadwal sholat hari ini
 * (agar UI tetap bisa tampil walau API/lokasi gagal).
 */
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { PREF_STORE_NAME, PREF_KEY_SCHEDULE, PREF_KEY_DATE } from '../common/Constants.ets';

const DOMAIN: number = 0x0000;
const TAG: string = 'MySholat|Prefs';

class PreferenceWrapper {
  private store: preferences.Preferences | null = null;

  /** Inisialisasi store. Dipanggil sekali dari EntryAbility.onCreate. */
  async init(context: common.Context): Promise<void> {
    try {
      this.store = await preferences.getPreferences(context, PREF_STORE_NAME);
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'getPreferences failed: %{public}s', e.message);
    }
  }

  async setString(key: string, value: string): Promise<void> {
    if (!this.store) { return; }
    try {
      await this.store.put(key, value);
      await this.store.flush();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setString(%{public}s) failed', key);
    }
  }

  async getString(key: string, def: string): Promise<string> {
    if (!this.store) { return def; }
    try {
      return await this.store.get(key, def) as string;
    } catch (err) {
      return def;
    }
  }

  async setNumber(key: string, value: number): Promise<void> {
    if (!this.store) { return; }
    try {
      await this.store.put(key, value);
      await this.store.flush();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setNumber(%{public}s) failed', key);
    }
  }

  async getNumber(key: string, def: number): Promise<number> {
    if (!this.store) { return def; }
    try {
      return await this.store.get(key, def) as number;
    } catch (err) {
      return def;
    }
  }

  /* ======================================================================
   * API TERSIRAT untuk strategi cache jadwal sholat (PrayerApiService).
   * Key terpusat di Constants.ets agar tidak ada string literal berserakan.
   * ====================================================================== */

  /** Simpan `cachedSchedule` — NormalizedDailySchedule yang di-JSON.stringify. */
  async saveCachedSchedule(jsonStr: string): Promise<void> {
    await this.setString(PREF_KEY_SCHEDULE, jsonStr);
  }

  /** Muat `cachedSchedule` mentah ('' bila belum pernah disimpan). */
  async loadCachedSchedule(): Promise<string> {
    return await this.getString(PREF_KEY_SCHEDULE, '');
  }

  /** Simpan tanggal fetch terakhir "YYYY-MM-DD" (penanda kesegaran cache harian). */
  async saveLastFetchDate(dateStr: string): Promise<void> {
    await this.setString(PREF_KEY_DATE, dateStr);
  }

  /** Baca tanggal fetch terakhir ('' bila kosong). */
  async loadLastFetchDate(): Promise<string> {
    return await this.getString(PREF_KEY_DATE, '');
  }

}

/** Singleton yang dipakai lintas service. */
export const preference: PreferenceWrapper = new PreferenceWrapper();
