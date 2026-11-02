/**
 * PermissionService.ets
 * ---------------------
 * Menangani permintaan izin lokasi runtime (Onboarding/Permission):
 *  - ohos.permission.APPROXIMATELY_LOCATION (harus diminta lebih dulu)
 *  - ohos.permission.LOCATION
 * Catatan: APPROXIMATELY_LOCATION adalah "satu-satunya" permission yang boleh
 * berada di dalam satu request yang sama dengan LOCATION; jika LOCATION saja
 * yang diminta tanpa APPROXIMATELY_LOCATION, sistem akan menolak (error 12100001).
 */
import { abilityAccessCtrl, bundleManager, common, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'MySholat|Permission';

export class PermissionService {
  /** Cek apakah permission sudah diberikan tanpa memicu dialog. */
  static async isGranted(permission: Permissions): Promise<boolean> {
    try {
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const bundleInfo: bundleManager.BundleInfo =
        await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      const tokenId: number = bundleInfo.appInfo.accessTokenId;
      const grantStatus: abilityAccessCtrl.GrantStatus =
        await atManager.checkAccessToken(tokenId, permission);
      return grantStatus === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'checkAccessToken failed: code=%{public}d msg=%{public}s', e.code, e.message);
      return false;
    }
  }

  /**
   * Minta izin lokasi ke user saat onboarding.
   * @returns true jika keduanya granted, false jika user menolak.
   */
  static async requestLocationPermissions(context: common.UIAbilityContext): Promise<boolean> {
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    const perms: Permissions[] = ['ohos.permission.APPROXIMATELY_LOCATION', 'ohos.permission.LOCATION'];
    try {
      const result = await atManager.requestPermissionsFromUser(context, perms);
      // Semua permission dalam satu request harus granted agar fix location bekerja.
      const allGranted: boolean = result.authResults.every((r: number) => r === 0);
      if (!allGranted) {
        hilog.warn(DOMAIN, TAG, 'User menolak izin lokasi. authResults=%{public}s',
          JSON.stringify(result.authResults));
      }
      return allGranted;
    } catch (err) {
      const e = err as BusinessError;
      // 12100001: user menekan "tolak" / request dibatalkan
      hilog.error(DOMAIN, TAG, 'requestPermissionsFromUser failed: %{public}s', e.message);
      return false;
    }
  }

  /** Status lengkap untuk ditampilkan di UI (banner error bila ditolak). */
  static async hasAnyLocationPermission(): Promise<boolean> {
    const approx: boolean = await PermissionService.isGranted('ohos.permission.APPROXIMATELY_LOCATION');
    const fine: boolean = await PermissionService.isGranted('ohos.permission.LOCATION');
    return approx || fine;
  }
}
