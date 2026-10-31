// Offline checks of the autofill probe on saved frames (autofill_debug=1 saves probe<N>_0..3.bmp):
//   test_autofill.exe <dir> <N>
// Runs the real detector (changed, blobs, judge) on the frames as captured, then on altered copies that must NOT pass
// as a masked field: the second glyph replaced by another image (a clear monospaced field), the erase left undone
// (a stray character), the caret removed from the erase frame. Exit 0 only if every case gives what it must.
#include "autofill.h"
#include <cstdio>

using namespace autofill;

static bool load(const std::wstring& path, Frame& f) {
    FILE* in = nullptr;
    if (_wfopen_s(&in, path.c_str(), L"rb") != 0 || !in) return false;
    BITMAPFILEHEADER fh;
    BITMAPINFOHEADER ih;
    bool ok = fread(&fh, sizeof(fh), 1, in) == 1 && fread(&ih, sizeof(ih), 1, in) == 1 && ih.biBitCount == 32;
    if (ok) {
        f.w = ih.biWidth;
        f.h = ih.biHeight < 0 ? -ih.biHeight : ih.biHeight;
        f.px.resize(static_cast<size_t>(f.w) * f.h * 4);
        fseek(in, fh.bfOffBits, SEEK_SET);
        ok = fread(f.px.data(), 1, f.px.size(), in) == f.px.size();
    }
    fclose(in);
    return ok;
}

// The detector part of probe(): what judge() says about every candidate pair. 1 masked, 2 clear, 0 none, -1 several.
static int detect(const Frame& f0, const Frame& f1, const Frame& f2, const Frame& g, Verdict& out) {
    auto m01 = changed(f0, f1), m12 = changed(f1, f2), m23 = changed(f2, g);
    std::vector<Box> b1 = blobs(m01, f0.w, f0.h), b2 = blobs(m12, f0.w, f0.h);
    int passed = 0;
    for (const Box& a : b1)
        for (const Box& b : b2) {
            int reach = 3 * (a.w() > a.h() ? a.w() : a.h());
            if (abs(a.y0 - b.y0) > 3 || abs(a.y1 - b.y1) > 3 || b.x0 < a.x1 - 2 || b.x0 > a.x1 + reach) continue;
            Verdict v = judge(nullptr, f0, f1, f2, g, m01, m12, m23, a, b);
            if (v.ok) {
                ++passed;
                out = v;
            }
        }
    return passed == 1 ? (out.masked ? 1 : 2) : passed == 0 ? 0 : -1;
}

static int failures = 0;
static void expect(const wchar_t* name, int got, bool good, const Verdict& v) {
    wprintf(L"%s %s: result %d (caret %d->%d->%d, glyph distance %d)\n", good ? L"PASS" : L"FAIL", name, got, v.x0, v.x1,
            v.x2, v.glyph_distance);
    if (!good) ++failures;
}

int wmain(int argc, wchar_t** argv) {
    if (argc != 3) return 2;
    std::wstring base = std::wstring(argv[1]) + L"\\probe" + argv[2] + L"_";
    Frame f[4];
    for (int i = 0; i < 4; ++i)
        if (!load(base + std::to_wstring(i) + L".bmp", f[i])) {
            wprintf(L"cannot load frame %d\n", i);
            return 2;
        }
    Verdict v;
    int r = detect(f[0], f[1], f[2], f[3], v);
    expect(L"real frames are a masked field", r, r == 1, v);
    if (r != 1) return 1;
    Verdict real = v;

    // a clear monospaced field: the second glyph drawn differently (its image flipped upside down), same advance
    Frame alt = f[2];
    for (int y = real.y0; y <= real.y1; ++y)
        for (int x = real.x1 + 3; x < real.x2 - 2; ++x)
            for (int c = 0; c < 4; ++c)
                alt.px[(static_cast<size_t>(y) * alt.w + x) * 4 + c] =
                    f[2].px[(static_cast<size_t>(real.y1 - (y - real.y0)) * alt.w + x) * 4 + c];
    Verdict v2;
    r = detect(f[0], f[1], alt, f[3], v2);
    expect(L"a different second glyph is not a mask", r, r != 1, v2);

    // the erase left undone: the frame after the erase is the frame with both glyphs
    Verdict v3;
    r = detect(f[0], f[1], f[2], f[2], v3);
    expect(L"no erase is not a mask", r, r != 1, v3);

    // the caret missing after the erase: its start columns restored from the frame before the probe
    Frame nocaret = f[3];
    for (int y = real.y0; y <= real.y1; ++y)
        for (int x = real.x0 - 3; x <= real.x0 + 3; ++x)
            for (int c = 0; c < 4; ++c)
                nocaret.px[(static_cast<size_t>(y) * nocaret.w + x) * 4 + c] =
                    f[0].px[(static_cast<size_t>(y) * nocaret.w + x) * 4 + c];
    Verdict v4;
    r = detect(f[0], f[1], f[2], nocaret, v4);
    expect(L"no caret after the erase is not a mask", r, r != 1, v4);

    wprintf(L"%d failure(s)\n", failures);
    return failures ? 1 : 0;
}
