# ML Kit barcode scanning ships its model in the APK (fully offline). R8 must not
# strip the model loader or the scanner silently returns zero barcodes in release
# builds while working perfectly in debug — a nasty class of bug to chase down.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }
-dontwarn com.google.mlkit.**

# Flutter embedding + our pose plugin are reached reflectively.
-keep class io.flutter.** { *; }
-keep class org.suraksha.surakshaar.** { *; }

# Flutter's embedding references Play Core for deferred components and Play
# Store split installs. SurakshaAR uses neither — the whole point is an APK that
# is sideloaded onto a contract worker's phone and never talks to Play Services
# or the network. The classes are genuinely absent, so R8 is told not to warn
# rather than the Play Core dependency being added back in.
-dontwarn com.google.android.play.core.**
-dontwarn io.flutter.embedding.android.FlutterPlayStoreSplitApplication
-dontwarn io.flutter.embedding.engine.deferredcomponents.**
