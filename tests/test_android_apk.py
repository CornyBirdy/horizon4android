import unittest

from tools import check_android_apk

ENGINE = [
    "AndroidManifest.xml",
    "classes.dex",
    "resources.arsc",
    "res/drawable-xxxhdpi/ic_launcher.png",
    "lib/",
    "lib/arm64-v8a/",
    "lib/arm64-v8a/libhorizon_android.so",
    "META-INF/ANDROIDD.SF",
    "META-INF/ANDROIDD.RSA",
]


class AndroidApkTests(unittest.TestCase):
    def test_engine_only_apk_passes(self):
        self.assertEqual(check_android_apk.problems(ENGINE, 40 << 20), [])

    def test_game_content_is_rejected(self):
        for extra in [
            "assets/minecraft/textures/block/stone.png",
            "assets/horizon-resources.json",
            "resources/horizon-resources.json",
            "lib/arm64-v8a/client.jar",
            "res/raw/sound.ogg",
            "minecraft/client.jar",
            "classes2.dex",
            "data/minecraft/loot_table/x.json",
            "lib/armeabi-v7a/libx.so",
        ]:
            self.assertTrue(check_android_apk.problems(ENGINE + [extra], 40 << 20), extra)

    def test_a_huge_apk_is_rejected(self):
        self.assertTrue(check_android_apk.problems(ENGINE, 400 << 20))


if __name__ == "__main__":
    unittest.main()
