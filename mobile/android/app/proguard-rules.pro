# Firebase and ML Kit discover registrars by class name and instantiate them
# reflectively. Keep the entry-point class and its public no-argument constructor.
-keep class * implements com.google.firebase.components.ComponentRegistrar {
    public <init>();
}
