#!/usr/bin/env python3
import os
import re
import sys

def main():
    android_dir = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "android")
    gradle_groovy = os.path.join(android_dir, "app", "build.gradle")
    gradle_kts = os.path.join(android_dir, "app", "build.gradle.kts")

    if os.path.isfile(gradle_kts):
        target = gradle_kts
        is_kts = True
    elif os.path.isfile(gradle_groovy):
        target = gradle_groovy
        is_kts = False
    else:
        print(f"[configure-signing] Warning: Neither build.gradle nor build.gradle.kts found in {android_dir}/app")
        return

    with open(target, "r", encoding="utf-8") as f:
        content = f.read()

    if "keystoreProperties" in content:
        print(f"[configure-signing] Signing already configured in {target}")
        return

    print(f"[configure-signing] Configuring release signing in {target} (Kotlin DSL: {is_kts})")

    if is_kts:
        header = """import java.util.Properties
import java.io.FileInputStream

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

"""
        signing_block = """
    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = keystoreProperties["storeFile"]?.let { file(it as String) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }
    buildTypes {
        getByName("release") {
            signingConfig = signingConfigs.getByName("release")
        }
    }
"""
    else:
        header = """def keystoreProperties = new Properties()
def keystorePropertiesFile = rootProject.file('key.properties')
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))
}

"""
        signing_block = """
    signingConfigs {
        release {
            keyAlias = keystoreProperties['keyAlias']
            keyPassword = keystoreProperties['keyPassword']
            storeFile = keystoreProperties['storeFile'] ? file(keystoreProperties['storeFile']) : null
            storePassword = keystoreProperties['storePassword']
        }
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.release
        }
    }
"""

    new_content = header + content
    # Insert signing block right inside `android {`
    new_content = re.sub(r'android\s*\{', 'android {\n' + signing_block, new_content, count=1)

    with open(target, "w", encoding="utf-8") as f:
        f.write(new_content)

    print(f"[configure-signing] Successfully configured signing in {target}")

if __name__ == "__main__":
    main()
