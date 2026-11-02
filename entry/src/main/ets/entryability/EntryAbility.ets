/**
 * EntryAbility.ets
 * ----------------
 * - Inisialisasi Preferences (cache) saat onCreate.
 * - onNewWant: dipanggil ketika ReminderAgent (pengingat H-10 menit) fired
 *   melalui WantAgent — sistem menyalakan ability, kita cukup log; notifikasi
 *   sudah ditampilkan oleh sistem reminder, lalu UI lanjut (onPageShow refresh).
 */
import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { preference } from '../services/PreferenceService.ets';

const DOMAIN = 0x0000;
const TAG: string = 'MySholat|Ability';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    // Siapkan store cache lokal sebelum halaman pertama memakai service lain.
    preference.init(this.context);
    hilog.info(DOMAIN, TAG, 'Ability onCreate');
  }

  /** Dipicu saat reminder agent menembakkan WantAgent ke aplikasi. */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onNewWant dari ReminderAgent: %{public}s', JSON.stringify(want.parameters ?? {}));
    // Tidak perlu fetch ulang di sini — onPageShow di halaman Index yang menangani
    // sinkronisasi jadwal & penghitungan ulang countdown secara hemat daya.
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'Ability onForeground');
  }

  onBackground(): void {
    // Countdown & interval sudah dihentikan di level halaman (onPageHide),
    // sehingga tidak ada timer aktif saat watch standby -> baterai awet.
    hilog.info(DOMAIN, TAG, 'Ability onBackground');
  }
}
