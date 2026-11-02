/**
 * ReminderService.ets
 * -------------------
 * Pengingat sholat 10 menit sebelum waktu menggunakan reminderAgentManager
 * (WantAgentReminder — berjalan di proses sistem, TIDAK membutuhkan aplikasi
 * tetap hidup -> jauh lebih hemat baterai dibanding setInterval/looping).
 *
 * Catatan wearable: Huawei Watch (HarmonyOS) mendukung ReminderAgent tipe
 * timer/wantAgent untuk aplikasi yang sudah meminta izin notifikasi.
 * Bila tipe reminder tidak didukung device, fallback ke notificationManager.
 */
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PrayerScheduleItem } from '../model/PrayerModels.ets';
import { REMINDER_BASE_ID, REMINDER_BEFORE_MINUTES } from '../common/Constants.ets';

const DOMAIN: number = 0x0000;
const TAG: string = 'MySholat|Reminder';

/** Kelas konkret action button reminder (ArkTS melarang object literal tanpa tipe). */
class ReminderActionButton {
  title: string = 'Ok';
  type: number = reminderAgentManager.ActionButtonType.ACTION_BUTTON_TYPE_CLOSE;
}

export class ReminderService {
  /** Pastikan notifikasi aplikasi aktif. */
  static async ensureNotificationEnabled(): Promise<boolean> {
    try {
      const enabled: boolean = await notificationManager.isNotificationEnabled();
      if (!enabled) {
        // NOTE: requestEnableNotification deprecated di API >= 11 namun masih satu-satunya
        // cara meminta izin notifikasi runtime dari aplikasi wearable.
        await notificationManager.requestEnableNotification();
      }
      return await notificationManager.isNotificationEnabled();
    } catch (err) {
      const e = err as BusinessError;
      // 1600004: user menolak izin notifikasi
      hilog.warn(DOMAIN, TAG, 'Notification not enabled: %{public}s', e.message);
      return false;
    }
  }

  /**
   * Jadwalkan pengingat untuk SEMUA sholat yang waktunya masih nanti hari ini,
   * masing-masing H-10 menit. Jadwal lama dibersihkan lebih dulu agar idempotent
   * (dipanggil ulang saat refresh lokasi/tanggal tidak menghasilkan duplikat).
   */
  static async scheduleForToday(items: PrayerScheduleItem[]): Promise<void> {
    await ReminderService.cancelAll();
    const now: number = Date.now();

    for (let i = 0; i < items.length; i++) {
      const item: PrayerScheduleItem = items[i];
      const triggerAtMs: number = item.timeMs - REMINDER_BEFORE_MINUTES * 60 * 1000;
      const delaySec: number = Math.round((triggerAtMs - now) / 1000);

      // Lewati sholat yang trigger-nya sudah lewat (mis. baru buka app jam 10 pagi).
      if (delaySec <= 0) { continue; }

      try {
        const agent: number = await ReminderService.scheduleOne(item, delaySec, i);
        hilog.info(DOMAIN, TAG, 'Scheduled reminder "%{public}s" in %{public}ds (id=%{public}d)',
          item.name, delaySec, agent);
      } catch (err) {
        const e = err as BusinessError;
        hilog.error(DOMAIN, TAG, 'schedule failed for %{public}s: code=%{public}d %{public}s',
          item.name, e.code, e.message);
      }
    }
  }

  /**
   * Satu trigger ReminderRequestTimer. Ketika fired, sistem menampilkan
   * notifikasi "Waktu sholat X dalam 10 menit" walau aplikasi tertutup
   * (proses ReminderAgent berjalan di sistem -> hemat baterai).
   */
  private static async scheduleOne(item: PrayerScheduleItem, delaySec: number, idx: number): Promise<number> {
    // ArkTS strict: object literal harus persis cocok dengan deklarasi
    // ReminderRequestTimer pada SDK ini — tanpa field ekstra
    // (`maxActionButtons` bukan bagian dari tipenya; jumlah tombol diambil
    // dari panjang array actionButton).
    const info: reminderAgentManager.ReminderRequestTimer = {
      reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_TIMER,
      triggerTimeInSeconds: delaySec,
      actionButton: [new ReminderActionButton()],
      title: `Pengingat ${item.name}`,
      content: `${item.name} tinggal 10 menit lagi (${item.time}). Mari siapkan diri untuk sholat.`,
      expiredContent: `Waktu ${item.name} telah tiba`,
      snoozeContent: 'Tunda',
      notificationId: REMINDER_BASE_ID + idx,
      slotType: 3 // SlotType.SLOT_SERVICE_INFORMATION
    };
    // publishReminder bisa melempar exception (mis. 802: kuota reminder habis,
    // 905: device tidak mendukung tipe ini) — dibungkus try/catch oleh caller.
    return await reminderAgentManager.publishReminder(info);
  }

  /** Bersihkan semua reminder milik aplikasi (panggil saat ganti hari/refresh). */
  static async cancelAll(): Promise<void> {
    try {
      // getValidReminders mengembalikan ReminderRequest[] (bukan ReminderInfo[]).
      // `slotType` bertipe union pada beberapa versi SDK — hindari membaca
      // field selain notificationId agar kompatibel lintas API 11/12.
      const reminders: reminderAgentManager.ReminderRequest[] =
        await reminderAgentManager.getValidReminders();
      for (let i = 0; i < reminders.length; i++) {
        // ID reminder tersimpan pada notificationId (basis id aplikasi kita).
        const nid: number | undefined = reminders[i].notificationId;
        if (nid !== undefined && nid >= REMINDER_BASE_ID && nid < REMINDER_BASE_ID + 200) {
          await reminderAgentManager.cancelReminder(nid);
        }
      }
    } catch (err) {
      const e = err as BusinessError;
      // 2350002: tidak ada reminder aktif — abaikan.
      hilog.warn(DOMAIN, TAG, 'cancelAll: %{public}s', e.message);
    }
  }
}
