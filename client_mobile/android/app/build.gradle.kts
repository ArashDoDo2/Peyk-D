plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.client_mobile"
    
    // ارتقا به 36 برای سازگاری با پکیج‌های جدید (مثل Secure Storage)
    compileSdk = 36 
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    defaultConfig {
        applicationId = "com.example.client_mobile"
        
        minSdk = 24 
        // هدف اصلی شما همچنان اندروید ۱۴ است
        targetSdk = 34 
        
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // استفاده از تنظیمات دیباگ برای تست سریع روی گوشی دیگران
            signingConfig = signingConfigs.getByName("debug")
            
            // غیرفعال کردن Minify برای جلوگیری از حذف کدهای Go (Gomobile)
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}