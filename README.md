# CAiPhoneDuoStatus 1.5.9 逆向重構

逆向對象：`com.callassist.caiphoneduostatus_1.5.9_iphoneos-arm64e.deb`（fat binary: arm64 + arm64e PAC）
工具：llvm-otool / llvm-nm / strings / llvm-objdump

## 二進制事實（確定）
- 編譯：Xcode + iOS 17.2 SDK + 蘋果原版 ld64 v1267（所以是真 arm64e）
- 純 ObjC/C++（無 Swift），鏈接 libsubstrate（`@loader_path/.jbroot/usr/lib/libsubstrate.dylib`）
- 注入目標僅 SpringBoard
- 導入符號：`MSHookMessageEx`、`objc_setAssociatedObject`、`NSHashTable weakObjectsHashTable`
- CG 繪製原語：`CGContextAddArc / FillEllipseInRect / StrokePath / SetLineWidth`（`___sincos_stret` 證明圓環角度計算）
- 觀察 `SBControlCenterController` 的 Present/Dismiss 通知
- 唯一自定義類：`CANativeStatusState`，屬性：`battery batteryFrame cellular cellularFrame
  cellularSource network networkFrame applyingLayout host hasBaseline`

## 行為推斷（高置信度）
它**不添加任何自定義 UIView**，而是：
1. 用 MSHookMessageEx **替換原生狀態欄控件的方法**，讓系統控件自己重畫成 Duo 樣式
   - `STUIStatusBarForegroundView` → `layoutSubviews`：把電池/Wi-Fi/訊號控件重排為豎排，目標位置存進關聯對象 CANativeStatusState；`applyingLayout` 防遞歸
   - `STUIStatusBarStaticBatteryView`(即 `_UIBatteryView`) → `drawRect:`：忽略原生電池繪製，按 `chargePercent` 用 CGContextAddArc 畫圓環；`tintColorDidChange` 適配深淺色
   - `STUIStatusBarCellularSignalView` → `drawRect:`：按 `numberOfActiveBars` 畫 4 個圓點
   - `STUIStatusBarWifiSignalView` → 縮小/移位（圓環下方）
2. 數據（電量/充電態/訊號格/Wi-Fi/4G-5G）全部來自原生控件自己的屬性——系統每秒更新，無需 IOKit/CoreTelephony
3. `weakObjectsHashTable` 跟蹤所有 ForegroundView；`host`/`didMoveToWindow`/`nextResponder` 過濾只改 SpringBoard 主狀態欄

## 本目錄
- `Tweak.xm` —— 按上述架構重構的行為等價源碼（乾淨重寫，非反編譯複製）
- 注意：hook 的是系統私有類，不同 iOS 版本類名可能變化（iOS 17 為 `STUIStatusBar*`）
