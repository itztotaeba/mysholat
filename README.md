# MySholat — Pengingat Sholat untuk Huawei Watch 5 (HarmonyOS / ArkTS)

Aplikasi wearable **Pengingat Sholat** berbasis HarmonyOS (DevEco Studio, ArkTS declarative UI, deviceType `wearable`).

## ✨ Fitur
| Fitur | Implementasi |
|---|---|
| Onboarding izin lokasi (`ohos.permission.LOCATION` + `APPROXIMATELY_LOCATION`) | `services/PermissionService.ets` |
| Deteksi Latitude/Longitude + reverse geocoding nama kota | `services/LocationService.ets` (geoLocationManager, ONE_SINGLE agar hemat baterai) |
| Jadwal 5 waktu (Subuh–Isya) dari **API Aladhan** `method=20` (Kemenag RI) | `services/PrayerApiService.ets` |
| Kartu "Sholat Berikutnya" + countdown di bagian paling atas | `pages/Index.ets` + `viewmodel/CountdownTimer.ets` |
| Notifikasi pengingat **10 menit sebelum sholat**, tetap jalan saat app tertutup | `services/ReminderService.ets` (`reminderAgentManager` / fallback `notificationManager`) |
| Cache jadwal & koordinat offline | `services/PreferenceService.ets` (`@ohos.data.preferences`) |

## 🗂 Struktur Proyek
```
entry/src/main/
├── ets/
│   ├── common/Constants.ets          # Endpoint API, warna tema, konstanta reminder
│   ├── model/PrayerModels.ets        # Interface response Aladhan + PrayerScheduleItem
│   ├── services/
│   │   ├── PermissionService.ets     # Runtime permission lokasi
│   │   ├── LocationService.ets       # GPS fix + reverse geocoding
│   │   ├── PrayerApiService.ets      # HTTP GET api.aladhan.com/v1/timings
│   │   ├── ReminderService.ets       # reminderAgentManager H-10 menit
│   │   └── PreferenceService.ets     # Cache lokal
│   ├── viewmodel/
│   │   ├── PrayerViewModel.ets       # Orkestrasi state (MVVM ringan)
│   │   └── CountdownTimer.ets        # Timer presisi-per-detik yang hemat baterai
│   ├── pages/Index.ets               # UI wearable (List + kartu next prayer)
│   └── entryability/EntryAbility.ets # Lifecycle + onNewWant dari ReminderAgent
└── module.json5                      # requestedPermissions (location, internet,
                                      #  NOTIFICATION, PUBLISH_AGENT_REMINDER)
```

## 🔌 API
```
GET https://api.aladhan.com/v1/timings?latitude={lat}&longitude={lon}&method=20
```
Field yang diparse: `data.timings.Fajr / Dhuhr / Asr / Maghrib / Isha` (suffix zona `(+07)` dibuang).

## 🔋 Strategi Hemat Baterai
1. **Reminder = ReminderAgent sistem** — aplikasi tidak perlu hidup di background; tidak ada polling.
2. **Countdown** memakai satu-shot `setTimeout` yang self-reschedule ke batas detik berikutnya, dan **dihentikan otomatis** saat `onPageHide` (layar watch mati / app background).
3. **GPS ONE_SINGLE** dengan timeout 10 detik (bukan continuous tracking).
4. Refresh jaringan maksimal 1×/30 menit saat foreground + deteksi ganti hari.

## 🛡 Error Handling
- Izin lokasi ditolak → banner merah "Izin lokasi ditolak…" + tetap menampilkan cache/default Jakarta.
- API gagal & tidak ada cache → pesan **"Gagal memuat jadwal"** + tombol *Coba Lagi*.
- API gagal tapi cache hari ini ada → schedule disajikan dari cache.

## 🚀 Build
Buka project di **DevEco Studio** (SDK HarmonyOS 5.x / API 12+), device target: `wearable` (Huawei Watch 5), lalu *Run*. Signing konfigurasi lewat *File > Project Structure > Signing Configs*.
