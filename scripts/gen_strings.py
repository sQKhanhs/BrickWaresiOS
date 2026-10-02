#!/usr/bin/env python3
"""Generate BrickWares/Localizable.xcstrings from the Android app's strings.xml (en + vi).

The iOS app uses the SAME string keys as Android (L("home_collection_value")), so copy changes are
made once and regenerated here:   python3 scripts/gen_strings.py
iOS-only strings live in IOS_ONLY below.
"""
import html, json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ANDROID_RES = os.environ.get(
    "BRICKWARES_ANDROID_RES",
    os.path.join(os.path.dirname(ROOT), "BrickWaresAndroid", "app", "src", "main", "res"),
)
OUT = os.path.join(ROOT, "BrickWares", "Localizable.xcstrings")

# key: (en, vi). An entry here OVERRIDES an Android string of the same key — keep only what iOS
# genuinely needs to word differently, and prefer a new iOS-only key over shadowing a shared one.
IOS_ONLY = {
    "login_apple": ("Continue with Apple", "Tiếp tục với Apple"),
    "login_err_weak_password": ("That password is too weak. Try a longer one.", "Mật khẩu quá yếu. Hãy thử mật khẩu dài hơn."),
    "theme_system": ("System", "Hệ thống"),
    "settings_language_note": ("Change the app language in iOS Settings.", "Đổi ngôn ngữ ứng dụng trong Cài đặt iOS."),
    "settings_version_label": ("Version", "Phiên bản"),
    "settings_change_password": ("Change password", "Đổi mật khẩu"),
    "config_missing_title": ("Setup needed", "Cần thiết lập"),
    "config_missing_body": ("Add your Supabase key to Secrets.plist (see Secrets.example.plist), then rebuild.", "Thêm khoá Supabase vào Secrets.plist (xem Secrets.example.plist) rồi build lại."),
    "action_rate_now_ios": ("Rate on the App Store", "Đánh giá trên App Store"),
    "rate_prompt_body_ios": ("You’ve built quite a collection! If you have a moment, a rating on the App Store helps other collectors find the app.", "Bạn đã có một bộ sưu tập đáng nể! Nếu có chút thời gian, một đánh giá trên App Store sẽ giúp những người sưu tầm khác tìm thấy ứng dụng."),
    # Android has these as a <plurals> resource (home_theme_item_count), which this script does not read.
    "home_theme_item_one": ("%d item", "%d bộ"),
    "home_theme_item_other": ("%d items", "%d bộ"),
    # See-Detail sheet: deleting one copy / one sale asks first (iOS only; Android deletes at once there).
    "sd_delete_copy_confirm": ("Delete this copy of \"%1$s\"?", "Xóa bản sao này của \"%1$s\"?"),
    "sd_delete_sale_title": ("Delete sale", "Xóa lần bán"),
    "action_done": ("Done", "Xong"),
    "action_close": ("Close", "Đóng"),
    "action_edit": ("Edit", "Sửa"),
    "action_sell": ("Sell", "Bán"),
    "action_move_to_collection": ("Move to Collection", "Chuyển vào Bộ sưu tập"),
    "detail_minifigs_in_set": ("Minifigs in this set", "Minifig trong bộ này"),
    "minifig_exclusive": ("Exclusive", "Độc quyền"),
    "value_loading": ("…", "…"),
    "value_none": ("----", "----"),
    "search_suggestions_sets": ("Sets", "Bộ"),
    "search_suggestions_minifigs": ("Minifigs", "Minifig"),
    "pagination_page_of": ("Page %1$d of %2$d", "Trang %1$d / %2$d"),
    "sync_in_progress": ("Syncing…", "Đang đồng bộ…"),
    "search_clear_cd": ("Clear search", "Xóa tìm kiếm"),
}

SPEC = re.compile(r"%(\d+\$)?([sd])")


def convert(value: str) -> str:
    v = html.unescape(value)
    v = v.replace("\\n", "\n").replace("\\'", "'").replace('\\"', '"').replace("\\@", "@")
    # %1$s -> %1$@ , %1$d -> %1$lld  (Swift String / Int)
    return SPEC.sub(lambda m: "%" + (m.group(1) or "") + ("@" if m.group(2) == "s" else "lld"), v)


def load(path):
    text = open(path, encoding="utf-8").read()
    out = {}
    for m in re.finditer(r'<string name="([^"]+)"[^>]*>(.*?)</string>', text, re.S):
        out[m.group(1)] = convert(m.group(2).strip())
    return out


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def main():
    en = load(os.path.join(ANDROID_RES, "values", "strings.xml"))
    vi = load(os.path.join(ANDROID_RES, "values-vi", "strings.xml"))
    for key, (e, v) in IOS_ONLY.items():
        en[key], vi[key] = convert(e), convert(v)
    strings = {}
    missing = []
    for key in sorted(en):
        locs = {"en": unit(en[key])}
        if key in vi:
            locs["vi"] = unit(vi[key])
        else:
            missing.append(key)
        strings[key] = {"extractionState": "manual", "localizations": locs}
    catalog = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    print(f"wrote {len(strings)} keys -> {OUT}")
    if missing:
        print("no vi translation for:", ", ".join(missing), file=sys.stderr)


if __name__ == "__main__":
    main()
