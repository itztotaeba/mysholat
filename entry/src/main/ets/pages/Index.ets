/**
 * Index.ets — Halaman utama "Pengingat Sholat" (Huawei Watch 5)
 * ------------------------------------------------------------
 * UI/UX wearable-optimized:
 *  - Layar bulat: padding simetris, radius besar, tanpa elemen berlebihan.
 *  - Bagian PALING ATAS: kartu "Sholat Berikutnya" dengan warna aksen mencolok
 *    + hitungan mundur (countdown).
 *  - List 5 waktu sholat: font besar, kontras tinggi, ikon sederhana (emoji).
 *  - Scroll vertikal memakai komponen List.
 */
import { common } from '@kit.AbilityKit';
import { UIContext } from '@kit.ArkUI';
import { PrayerViewModel, LoadState } from '../viewmodel/PrayerViewModel.ets';
import { PrayerScheduleItem } from '../model/PrayerModels.ets';
import { AppColors, PrayerIcons } from '../common/Constants.ets';

/** Context UIAbility via getUIContext() — pengganti `getContext` yang deprecated. */
function abilityContextOf(ctx: UIContext): common.UIAbilityContext | undefined {
  try {
    return ctx.getHostContext() as common.UIAbilityContext;
  } catch (e) {
    return undefined;
  }
}

@Entry
@Component
struct Index {
  // State utama dipegang ViewModel (@Observed + @Track -> re-render presisi).
  @State vm: PrayerViewModel = new PrayerViewModel();

  aboutToAppear(): void {
    // getContext() deprecated -> gunakan this.getUIContext().getHostContext() (API 10+).
    const context: common.UIAbilityContext | undefined = abilityContextOf(this.getUIContext());
    this.vm.bootstrap(context);
  }

  onPageShow(): void {
    this.vm.onPageShow();
  }

  onPageHide(): void {
    // Hemat baterai: hentikan countdown & interval saat layar/watch background.
    this.vm.onPageHide();
  }

  aboutToDisappear(): void {
    this.vm.destroy();
  }

  build() {
    Column() {
      // ===== HEADER: lokasi user (hasil reverse geocoding) =====
      Row() {
        Text('📍').fontSize(13)
        Text(this.vm.cityName)
          .fontSize(13)
          .fontColor(AppColors.TEXT_SECONDARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 4 })
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')

      // ===== KARTU UTAMA: SHOLAT BERIKUTNYA (paling atas, warna mencolok) =====
      if (this.vm.loadState === LoadState.LOADING && this.vm.schedule.length === 0) {
        this.loadingView()
      } else {
        this.nextPrayerCard()
      }

      // ===== BANNER ERROR (izin ditolak / API gagal) =====
      if (this.vm.errorMessage.length > 0) {
        this.errorBanner()
      }

      // ===== LIST JADWAL 5 WAKTU =====
      List({ space: 6 }) {
        ForEach(this.vm.schedule, (item: PrayerScheduleItem) => {
          ListItem() {
            this.prayerRow(item)
          }
        }, (item: PrayerScheduleItem) => `${item.apiName}-${item.time}-${item.isNext}-${item.isPassed}`)
      }
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .layoutWeight(1)
      .width('92%')
      .padding({ top: 6 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColors.BG)
    .padding({ top: 14, bottom: 14 })
  }

  // ---------- Sub-view builders ----------

  @Builder
  nextPrayerCard() {
    Column({ space: 2 }) {
      Text('SHOLAT BERIKUTNYA')
        .fontSize(10)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColors.ACCENT)
        .letterSpacing(1.2)

      Text(this.vm.nextPrayerName.length > 0 ? this.vm.nextPrayerName : '—')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColors.TEXT_PRIMARY)

      Text(this.vm.nextPrayerTime)
        .fontSize(14)
        .fontColor(AppColors.TEXT_SECONDARY)

      // Countdown besar & jelas — update tiap detik via CountdownTimer hemat baterai.
      Text(this.vm.countdownText)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColors.ACCENT)
        .margin({ top: 2 })
    }
    .width('92%')
    .padding({ top: 10, bottom: 10 })
    .backgroundColor(AppColors.CARD)
    .borderRadius(20)
    .border({ width: 1, color: AppColors.ACCENT, style: BorderStyle.Solid })
    .margin({ top: 8, bottom: 6 })
  }

  @Builder
  prayerRow(item: PrayerScheduleItem) {
    Row() {
      // Ikon sederhana per waktu sholat (emoji — selalu tersedia di SDK wearable).
      Text(PrayerIcons.of(item.apiName))
        .fontSize(16)

      Text(item.name)
        .fontSize(16)
        .fontWeight(item.isNext ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(item.isPassed ? AppColors.PASSED : AppColors.TEXT_PRIMARY)
        .margin({ left: 10 })
        .layoutWeight(1)

      Text(item.time)
        .fontSize(16)
        .fontWeight(item.isNext ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(item.isNext ? AppColors.ACCENT :
          (item.isPassed ? AppColors.PASSED : AppColors.TEXT_PRIMARY))
        .fontFeature('"tnum" on') // digit tetap agar tidak bergeser tiap detik
    }
    .width('100%')
    .height(42)
    .padding({ left: 14, right: 14 })
    .backgroundColor(item.isNext ? AppColors.CARD : Color.Transparent)
    .borderRadius(14)
    .border(item.isNext ? { width: 1, color: AppColors.ACCENT } : { width: 0 })
  }

  @Builder
  errorBanner() {
    Column({ space: 6 }) {
      Text('⚠️').fontSize(16)
      Text(this.vm.errorMessage)
        .fontSize(11)
        .fontColor(AppColors.DANGER)
        .textAlign(TextAlign.Center)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      // Tombol retry hanya untuk kegagalan API (bukan penolakan permission).
      if (this.vm.loadState === LoadState.ERROR_API) {
        Button('Coba Lagi')
          .fontSize(12)
          .height(28)
          .backgroundColor(AppColors.ACCENT)
          .fontColor(AppColors.BG)
          .onClick(() => {
            const ctx: common.UIAbilityContext | undefined = abilityContextOf(this.getUIContext());
            this.vm.retry(ctx);
          })
      }
    }
    .width('92%')
    .padding(8)
    .backgroundColor('#2A1616')
    .borderRadius(14)
    .margin({ bottom: 6 })
  }

  @Builder
  loadingView() {
    Column({ space: 8 }) {
      LoadingProgress().width(32).height(32).color(AppColors.ACCENT)
      Text('Memuat jadwal sholat…').fontSize(12).fontColor(AppColors.TEXT_SECONDARY)
    }
    .width('92%')
    .padding({ top: 24, bottom: 24 })
    .justifyContent(FlexAlign.Center)
  }
}
