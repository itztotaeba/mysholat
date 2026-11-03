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
import { AppColors } from '../common/Constants.ets';

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
      // ===== HEADER: jam saat ini + lokasi user (hasil reverse geocoding) =====
      Column({ space: 1 }) {
        Text(this.vm.currentClock)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColors.TEXT_PRIMARY)
          .fontFeature('"tnum" on') // digit tetap agar jam tidak bergeser
        Row() {
          Text(this.vm.cityName)
            .fontSize(12)
            .fontColor(AppColors.TEXT_SECONDARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .margin({ bottom: 4 })

      // ===== KARTU KECIL: SHOLAT BERIKUTNYA (compact, satu baris) =====
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

      // ===== TOMBOL REFRESH — ambil ulang lokasi & jadwal (user pindah tempat) =====
      Button(this.vm.isRefreshing ? 'Memuat ulang…' : 'Refresh')
        .fontSize(12)
        .height(30)
        .width('60%')
        .enabled(!this.vm.isRefreshing)
        .backgroundColor(AppColors.CARD)
        .fontColor(AppColors.ACCENT)
        .borderRadius(15)
        .border({ width: 1, color: AppColors.BORDER_DARK_BLUE })
        .margin({ top: 6, bottom: 4 })
        .onClick(() => {
          const ctx: common.UIAbilityContext | undefined = abilityContextOf(this.getUIContext());
          this.vm.refresh(ctx);
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColors.BG)
    .padding({ top: 14, bottom: 14 })
  }

  // ---------- Sub-view builders ----------

  /**
   * Kartu "Sholat Berikutnya" versi KECIL/COMPACT (permintaan user):
   * label kecil di kiri, nama+jam dan countdown di kanan — hanya ~34px tinggi
   * sehingga daftar 5 waktu muat lebih lega di layar bulat watch.
   */
  @Builder
  nextPrayerCard() {
    Row() {
      Text('NEXT')
        .fontSize(9)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColors.ACCENT)
        .letterSpacing(1)
        .margin({ right: 8 })

      Column({ space: 1 }) {
        Text(`${this.vm.nextPrayerName.length > 0 ? this.vm.nextPrayerName : '—'} · ${this.vm.nextPrayerTime}`)
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColors.TEXT_PRIMARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        // Countdown update tiap detik via CountdownTimer hemat baterai.
        Text(this.vm.countdownText)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColors.ACCENT)
          .fontFeature('"tnum" on')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('92%')
    .height(40)
    .padding({ left: 14, right: 14 })
    .backgroundColor(AppColors.CARD)
    .borderRadius(16)
    .border({ width: 1, color: AppColors.BORDER_DARK_BLUE, style: BorderStyle.Solid })
    .margin({ top: 4, bottom: 4 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  prayerRow(item: PrayerScheduleItem) {
    Row() {
      Text(item.name)
        .fontSize(16)
        .fontWeight(item.isNext ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(item.isPassed ? AppColors.PASSED : AppColors.TEXT_PRIMARY)
        .margin({ left: 4 })
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
    .border({ width: 1, color: AppColors.BORDER_DARK_BLUE })
  }

  @Builder
  errorBanner() {
    Column({ space: 6 }) {
      Text(this.vm.errorMessage)
        .fontSize(11)
        .fontColor(AppColors.DANGER)
        .textAlign(TextAlign.Center)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      // Tombol "Coba Lagi" kini MEMANG mengulang pencarian dari awal:
      // forceRefresh=true melewati cache harian & mengambil ulang koordinat
      // GPS terbaru (dulu tombol ini terasa mati karena membentur negative
      // cache — sumber keluhan user "waktu muat habis").
      if (this.vm.loadState === LoadState.ERROR_API ||
          this.vm.loadState === LoadState.ERROR_NO_PERMISSION) {
        Button('Coba Lagi')
          .fontSize(12)
          .height(28)
          .backgroundColor(AppColors.ACCENT)
          .fontColor(AppColors.BG)
          .onClick(() => {
            const ctx: common.UIAbilityContext | undefined = abilityContextOf(this.getUIContext());
            this.vm.refresh(ctx);
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
