// L10n.swift — lightweight localisation. Strings live in one table per language so the whole app can
// be translated without a build step or a string catalog merge.
import SwiftUI

/// The app follows the system language. There is no in-app override.
enum L10n {
    /// Two-letter code derived from macOS, mapped onto the tables below.
    static var code: String {
        for preferred in Locale.preferredLanguages {
            if preferred.hasPrefix("zh") { return "zh-Hans" }
            if preferred.hasPrefix("ms") { return "ms" }
            if preferred.hasPrefix("en") { return "en" }
        }
        return "en"
    }

    static func s(_ key: String) -> String {
        guard code != "en", let table = tables[code] else { return key }
        return table[key] ?? key
    }


    static let tables: [String: [String: String]] = [
        "zh-Hans": [
            // settings
            "Storage": "存储",
            "Profiles": "配置文件",
            "Graphics": "图像",
            "Where Save and Save As put .sdprofile files.": "“存储”和“另存为”保存 .sdprofile 文件的位置。",
            "Starting folder when you pick an image for a key.": "为按键选择图像时的起始文件夹。",
            "Restore Defaults": "恢复默认",
            "Language": "语言",
            "Applies immediately · System follows macOS.": "立即生效 · 系统表示跟随 macOS。",
            "Follows the system setting.": "跟随系统设置。",
            "Choose…": "选择…",
            "Show in Finder": "在访达中显示",
            "Reset to the default folder": "重置为默认文件夹",
            "Folder problem": "文件夹问题",
            "Use Folder": "使用文件夹",
            "OK": "好",
            "Key": "按键",
            "Number": "编号",
            "Label": "名称",
            "Kind": "类型",
            "Button": "按钮",
            "Optional": "可选",
            "Graphic": "图标",
            "Images are resized to 85×85 and written to the key immediately.": "图像会调整为 85×85 并立即写入按键。",
            "Action": "操作",
            "Bound to": "已绑定",
            "Type": "类型",
            "Application": "应用程序",
            "Shortcut": "快捷键",
            "Record": "录制",
            "Script": "脚本",
            "Panel connected": "面板已连接",
            "Widgets · no input": "小组件 · 无输入",
            "Click to bind · drop an image to set its graphic": "点按以绑定 · 拖入图像可设置图标",
            "pages · limit": "页 · 上限",
            "This key does nothing.": "此按键没有操作。",
            // sidebar
            "On device": "已发送到设备",
            "Connected": "已连接",
            "Not connected": "未连接",
            "Model": "型号",
            "Firmware": "固件",
            "Send to Device": "发送到设备",
            // pages / keys
            "Keys": "按键",
            "Window": "窗口",
            "Pages": "页面",
            "Page": "页",
            // menu
            "New Profile": "新建配置文件",
            "Load Profile…": "载入配置文件…",
            "Save": "存储",
            "Save As…": "另存为…",
            "Remove Profile from Sidebar": "从边栏移除配置文件",
            "Duplicate Profile": "复制配置文件",
            "Settings…": "设置…",
            // actions
            "None": "无",
            "Key combination": "按键组合",
            "Open app": "打开应用",
            "Open URL": "打开网址",
            "Run script": "运行脚本",
            "Next page": "下一页",
            "Previous page": "上一页",
            "First page": "第一页",
            "Clear Action": "清除操作",
            "Choose Image…": "选择图像…",
            "Clear Image": "清除图像",
        ],
        "ms": [
            "Storage": "Storan",
            "Profiles": "Profil",
            "Graphics": "Grafik",
            "Where Save and Save As put .sdprofile files.": "Tempat Simpan dan Simpan Sebagai meletakkan fail .sdprofile.",
            "Starting folder when you pick an image for a key.": "Folder permulaan apabila anda memilih imej untuk kekunci.",
            "Restore Defaults": "Pulihkan Lalai",
            "Language": "Bahasa",
            "Applies immediately · System follows macOS.": "Berkuat kuasa serta-merta · Sistem mengikut macOS.",
            "Follows the system setting.": "Mengikut tetapan sistem.",
            "Choose…": "Pilih…",
            "Show in Finder": "Tunjuk dalam Finder",
            "Reset to the default folder": "Set semula kepada folder lalai",
            "Folder problem": "Masalah folder",
            "Use Folder": "Guna Folder",
            "OK": "OK",
            "Key": "Kekunci",
            "Number": "Nombor",
            "Label": "Label",
            "Kind": "Jenis",
            "Button": "Butang",
            "Optional": "Pilihan",
            "Graphic": "Grafik",
            "Images are resized to 85×85 and written to the key immediately.": "Imej diubah saiz kepada 85×85 dan ditulis ke kekunci serta-merta.",
            "Action": "Tindakan",
            "Bound to": "Terikat kepada",
            "Type": "Jenis",
            "Application": "Aplikasi",
            "Shortcut": "Pintasan",
            "Record": "Rakam",
            "Script": "Skrip",
            "Panel connected": "Panel bersambung",
            "Widgets · no input": "Widget · tiada input",
            "Click to bind · drop an image to set its graphic": "Klik untuk ikat · lepas imej untuk tetapkan grafik",
            "pages · limit": "halaman · had",
            "This key does nothing.": "Kekunci ini tidak berbuat apa-apa.",
            "On device": "Pada peranti",
            "Connected": "Bersambung",
            "Not connected": "Tidak bersambung",
            "Model": "Model",
            "Firmware": "Firmware",
            "Send to Device": "Hantar ke Peranti",
            "Keys": "Kekunci",
            "Window": "Tetingkap",
            "Pages": "Halaman",
            "Page": "Halaman",
            "New Profile": "Profil Baharu",
            "Load Profile…": "Muat Profil…",
            "Save": "Simpan",
            "Save As…": "Simpan Sebagai…",
            "Remove Profile from Sidebar": "Buang Profil dari Bar Sisi",
            "Duplicate Profile": "Duplikasi Profil",
            "Settings…": "Tetapan…",
            "None": "Tiada",
            "Key combination": "Gabungan kekunci",
            "Open app": "Buka aplikasi",
            "Open URL": "Buka URL",
            "Run script": "Jalankan skrip",
            "Next page": "Halaman seterusnya",
            "Previous page": "Halaman sebelumnya",
            "First page": "Halaman pertama",
            "Clear Action": "Kosongkan Tindakan",
            "Choose Image…": "Pilih Imej…",
            "Clear Image": "Kosongkan Imej",
        ],
    ]
}

/// Shorthand used across the views.
func t(_ key: String) -> String { L10n.s(key) }
