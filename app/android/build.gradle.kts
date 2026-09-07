allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// camera_android_camerax compiles against camera-core 1.5.x, whose public API is
// annotated with @NonNull on fields typed CallbackToFutureAdapter.Completer.
// Under AGP 9 that artifact is no longer placed on the javac classpath
// transitively, so annotation attachment fails with
// "class file for androidx.concurrent.futures.CallbackToFutureAdapter not found".
// Putting it back explicitly is the narrowest fix; it touches only that module.
subprojects {
    if (name == "camera_android_camerax") {
        plugins.withId("com.android.library") {
            dependencies {
                add("implementation", "androidx.concurrent:concurrent-futures:1.2.0")
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
