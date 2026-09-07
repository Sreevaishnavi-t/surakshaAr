# ML Kit barcode scanning ships its model in the APK (fully offline). R8 must not
# strip the model loader or the scanner silently returns zero barcodes in release
# builds while working perfectly in debug — a nasty class of bug to chase down.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }
-dontwarn com.google.mlkit.**

# Flutter embedding + our pose plugin are reached reflectively.
-keep class io.flutter.** { *; }
-keep class org.suraksha.surakshaar.** { *; }
