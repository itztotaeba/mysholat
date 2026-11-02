/**
 * CountdownTimer.ets
 * ------------------
 * Timer hitung mundur RAMAH BATERAI untuk layar watch.
 *
 * Strategi:
 *  - TIDAK memakai setInterval(1000) terus-menerus tanpa henti.
 *  - Satu-shot setTimeout yang presisi ke pergantian detik berikutnya;
 *    setelah fired, dijadwalkan lagi (self-rescheduling).
 *  - Saat aplikasi masuk background / layar mati (watch), timer dihentikan
 *    lewat stop(); akan disetel ulang saat foreground. Pengingat tetap
 *    ditangani ReminderAgent di level sistem, jadi countdown bukan sumber
 *    reminder utama — hanya visual.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'MySholat|Timer';

export class CountdownTimer {
  private targetMs: number = 0;
  private timerId: number = -1;
  private running: boolean = false;
  /** Callback dipanggil setiap detik selama running. */
  private onTick: (remainingMs: number) => void;

  constructor(onTick: (remainingMs: number) => void) {
    this.onTick = onTick;
  }

  /** Set target waktu baru; jika sedang berjalan, loop langsung pakai target baru. */
  setTarget(targetMs: number): void {
    this.targetMs = targetMs;
    if (!this.running) {
      // Jangan nyalakan timer bila target sudah lewat.
      if (targetMs > Date.now()) {
        this.start();
      }
      return;
    }
    this.scheduleNextTick();
  }

  start(): void {
    if (this.running) { return; }
    this.running = true;
    this.tickAndReschedule();
  }

  /** Panggil dari onPageHide / onBackground — hemat baterai watch. */
  stop(): void {
    this.running = false;
    if (this.timerId !== -1) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
  }

  isRunning(): boolean {
    return this.running;
  }

  private tickAndReschedule(): void {
    if (!this.running) { return; }
    const remaining: number = this.targetMs - Date.now();
    this.onTick(remaining > 0 ? remaining : 0);
    this.scheduleNextTick();
  }

  /** Jadwalkan callback tepat pada batas detik berikutnya (bukan drift 1000ms). */
  private scheduleNextTick(): void {
    if (!this.running) { return; }
    if (this.timerId !== -1) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
    const now: number = Date.now();
    const remaining: number = this.targetMs - now;

    if (remaining <= 0) {
      // Selesai: beri tahu UI 0, lalu matikan timer sendiri.
      this.onTick(0);
      this.stop();
      hilog.info(DOMAIN, TAG, 'Countdown finished, timer stopped to save battery.');
      return;
    }
    const delayToNextSecond: number = 1000 - (now % 1000);
    this.timerId = setTimeout(() => {
      this.tickAndReschedule();
    }, delayToNextSecond);
  }
}

/** Format ms -> "2j 15m 30d" gaya Indonesia, ringkas untuk layar bulat. */
export function formatCountdown(ms: number): string {
  if (ms <= 0) { return 'Waktunya sholat!'; }
  const totalSec: number = Math.floor(ms / 1000);
  const hours: number = Math.floor(totalSec / 3600);
  const minutes: number = Math.floor((totalSec % 3600) / 60);
  const seconds: number = totalSec % 60;
  const pad = (n: number): string => n.toString().padStart(2, '0');
  if (hours > 0) {
    return `${hours}j ${pad(minutes)}m ${pad(seconds)}d`;
  }
  return `${pad(minutes)}m ${pad(seconds)}d`;
}
