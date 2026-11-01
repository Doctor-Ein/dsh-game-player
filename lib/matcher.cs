using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

// Exact, same-scale RGB matching. Every physical pixel offset is searched; early
// rejection uses only accumulated squared error, so it cannot skip a valid hit.
public static class GpMatcher {
    public sealed class Hit { public int x, y, w, h; public double score; }
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);

    static byte[] Pixels(Bitmap image) {
        using (var rgb = new Bitmap(image.Width, image.Height, PixelFormat.Format24bppRgb)) {
            using (var g = Graphics.FromImage(rgb)) g.DrawImageUnscaled(image, 0, 0);
            var data = rgb.LockBits(new Rectangle(0, 0, rgb.Width, rgb.Height), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
            try {
                var bytes = new byte[rgb.Width * rgb.Height * 3];
                for (int y = 0; y < rgb.Height; y++)
                    Marshal.Copy(IntPtr.Add(data.Scan0, y * data.Stride), bytes, y * rgb.Width * 3, rgb.Width * 3);
                return bytes;
            } finally { rgb.UnlockBits(data); }
        }
    }

    public static Hit[] Find(Bitmap image, Bitmap template, double threshold, int maxResults) {
        if (double.IsNaN(threshold) || threshold < 0.8 || threshold > 1) throw new ArgumentException("threshold must be 0.8..1");
        if (maxResults < 1 || maxResults > 20) throw new ArgumentException("maxResults must be 1..20");
        int tw = template.Width, th = template.Height, iw = image.Width, ih = image.Height;
        if (tw < 3 || th < 3 || tw > 512 || th > 512) throw new ArgumentException("template must be 3..512 pixels per side");
        if ((long)iw * ih > 16000000) throw new ArgumentException("search image too large; restrict region");
        if (tw > iw || th > ih) return new Hit[0];
        byte[] src = Pixels(image), tpl = Pixels(template);
        int n = tw * th;
        var mean = new double[3];
        for (int i = 0; i < tpl.Length; i++) mean[i % 3] += tpl[i] / (double)n;
        var order = new int[n]; var energy = new double[n]; double variance = 0;
        for (int i = 0; i < n; i++) {
            order[i] = i;
            for (int c = 0; c < 3; c++) { double d = tpl[i * 3 + c] - mean[c]; energy[i] += d * d; }
            variance += energy[i];
        }
        if (variance / (n * 3) < 25) throw new ArgumentException("template has too little texture; include distinctive edges/text");
        // Distinctive pixels first makes rejection of unrelated backgrounds cheap.
        Array.Sort(order, delegate(int a, int b) { return energy[b].CompareTo(energy[a]); });
        var offsets = new int[n];
        for (int i = 0; i < n; i++) offsets[i] = ((order[i] / tw) * iw + order[i] % tw) * 3;
        double limit = (1 - threshold) * (1 - threshold) * 255 * 255 * n * 3;
        var candidates = new List<Hit>();
        var clock = Stopwatch.StartNew();
        for (int y = 0; y <= ih - th; y++) {
            if (clock.ElapsedMilliseconds > 15000) throw new TimeoutException("matching exceeded 15s; restrict search region or tighten threshold");
            if ((GetAsyncKeyState(0x7B) & 0x8000) != 0) throw new OperationCanceledException("matching aborted by F12");
            for (int x = 0; x <= iw - tw; x++) {
                long error = 0; int start = (y * iw + x) * 3;
                for (int i = 0; i < n; i++) {
                    int a = start + offsets[i], b = order[i] * 3;
                    int d0 = src[a] - tpl[b], d1 = src[a + 1] - tpl[b + 1], d2 = src[a + 2] - tpl[b + 2];
                    error += d0 * d0 + d1 * d1 + d2 * d2;
                    if (error > limit + 1e-6) break;
                }
                if (error <= limit + 1e-6) {
                    candidates.Add(new Hit { x = x, y = y, w = tw, h = th, score = 1 - Math.Sqrt(error / (n * 3.0)) / 255 });
                    if (candidates.Count > 100000) throw new ArgumentException("too many similar candidates; use a more distinctive template or smaller region");
                }
            }
        }
        candidates.Sort(delegate(Hit a, Hit b) {
            int rank = b.score.CompareTo(a.score);
            if (rank != 0) return rank;
            rank = a.y.CompareTo(b.y); return rank != 0 ? rank : a.x.CompareTo(b.x);
        });
        var result = new List<Hit>();
        foreach (var hit in candidates) {
            bool overlaps = false;
            foreach (var prior in result) {
                int ox = Math.Max(0, Math.Min(hit.x + tw, prior.x + tw) - Math.Max(hit.x, prior.x));
                int oy = Math.Max(0, Math.Min(hit.y + th, prior.y + th) - Math.Max(hit.y, prior.y));
                if (ox * oy > n * 0.3) { overlaps = true; break; }
            }
            if (!overlaps) result.Add(hit);
            if (result.Count >= maxResults) break;
        }
        return result.ToArray();
    }
}
