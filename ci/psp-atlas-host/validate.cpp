// Run the production metadata and ZIM readers; validate lookup and bounds.
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <vector>
#include <set>
#include <string>
#include "Common/Render/TextureAtlas.h"
#include "Common/Data/Format/ZIMLoad.h"
#include "Common/Data/Format/PNGLoad.h"
#include "Common/Data/Format/ZIMSave.h"
static void require(bool valid, const char *reason) {
  if (!valid) { std::fprintf(stderr, "%s\n", reason); std::exit(1); }
}
static bool bounds(float a, float b, float c, float d) {
  return std::isfinite(a) && std::isfinite(b) && std::isfinite(c) && std::isfinite(d)
    && a >= 0 && b >= 0 && c >= a && d >= b && c <= 1 && d <= 1;
}
int main(int argc, char **argv) {
  if (argc == 4 && std::strcmp(argv[1], "--zim4444") == 0) {
    int w, h;
    unsigned char *rgba = nullptr;
    require(pngLoad(argv[2], &w, &h, &rgba) == 1, "Production PNG loader rejected image");
    auto *copy = new uint8_t[w * h * 4];
    std::memcpy(copy, rgba, w * h * 4);
    std::free(rgba);
    FILE *output = std::fopen(argv[3], "wb");
    require(output != nullptr, "Cannot open ZIM output");
    SaveZIM(output, w, h, w * 4, ZIM_RGBA4444 | ZIM_ZSTD_COMPRESSED | ZIM_DITHER, copy);
    require(std::fclose(output) == 0, "Cannot finish ZIM output");
    return 0;
  }
  if (argc == 4 && std::strcmp(argv[1], "--png") == 0) {
    int w, h;
    unsigned char *rgba = nullptr;
    require(pngLoad(argv[2], &w, &h, &rgba) == 1, "Production PNG loader rejected image");
    FILE *output = std::fopen((std::string(argv[3]) + ".rgba").c_str(), "wb");
    require(output != nullptr, "Cannot open PNG dump");
    require(std::fwrite(rgba, 4, w * h, output) == static_cast<size_t>(w * h), "Cannot write PNG dump");
    require(std::fclose(output) == 0, "Cannot finish PNG dump");
    std::free(rgba);
    std::printf("{\"size\":[%d,%d]}\n", w, h);
    return 0;
  }
  require(argc == 3 || argc == 4, "Usage: atlas-validate atlas.meta atlas.zim [dump-prefix]");
  std::ifstream input(argv[1], std::ios::binary);
  require(input.good(), "Cannot open atlas metadata");
  std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(input)), {});
  Atlas atlas;
  require(atlas.LoadMeta(bytes.data(), bytes.size()), "Production metadata parser rejected atlas");
  int width[ZIM_MAX_MIP_LEVELS]{}, height[ZIM_MAX_MIP_LEVELS]{}, flags;
  uint8_t *pixels[ZIM_MAX_MIP_LEVELS]{};
  require(LoadZIM(argv[2], width, height, &flags, pixels) == 1, "Production ZIM parser rejected atlas");
  require(width[0] <= 4096 && height[0] <= 4096, "Atlas exceeds portable texture limit");
  size_t glyphs = 0;
  for (int i = 0; i < atlas.num_fonts; ++i) {
    const AtlasFont &font = atlas.fonts[i];
    require(atlas.getFont(FontID(font.name)) == &font, "Font ID lookup differs");
    require(std::isfinite(font.height) && font.height > 0 && font.ascend > 0, "Invalid font metrics");
    for (int r = 0; r < font.numRanges; ++r) {
      const auto &range = font.ranges[r];
      require(range.result_index >= 0 && range.end > range.start &&
        range.result_index + range.end - range.start <= font.numChars, "Invalid character range");
      for (int cp = range.start; cp < range.end; ++cp) {
        const auto &c = font.charData[range.result_index + cp - range.start];
        require(bounds(c.sx, c.sy, c.ex, c.ey), "Glyph is outside texture bounds");
        require(std::isfinite(c.ox) && std::isfinite(c.oy) && std::isfinite(c.wx), "Invalid glyph metrics");
        if (c.ex != 0 || c.ey != 0) { require(font.getChar(cp) != nullptr, "Required glyph lookup failed"); ++glyphs; }
      }
    }
  }
  for (int i = 0; i < atlas.num_images; ++i) {
    const auto &img = atlas.images[i];
    require(atlas.getImage(ImageID(img.name)) == &img, "Image ID lookup differs");
    require(img.w > 0 && img.h > 0 && bounds(img.u1, img.v1, img.u2, img.v2), "Invalid image dimensions/bounds");
  }
  if (argc == 4) {
    const std::string prefix = argv[3];
    FILE *json = std::fopen((prefix + ".json").c_str(), "wb");
    require(json != nullptr, "Cannot open metadata dump");
    std::fprintf(json, "{\"size\":[%d,%d],\"format\":%d,\"images\":[", width[0], height[0], flags & ZIM_FORMAT_MASK);
    for (int i = 0; i < atlas.num_images; ++i) {
      const auto &img = atlas.images[i];
      std::fprintf(json, "%s{\"name\":\"%s\",\"size\":[%d,%d],\"uv\":[%.9g,%.9g,%.9g,%.9g]}",
        i ? "," : "", img.name, img.w, img.h, img.u1, img.v1, img.u2, img.v2);
    }
    std::fprintf(json, "],\"fonts\":[");
    for (int i = 0; i < atlas.num_fonts; ++i) {
      const auto &f = atlas.fonts[i];
      std::fprintf(json, "%s{\"name\":\"%s\",\"height\":%.9g,\"ascend\":%.9g,\"padding\":%.9g,\"slope\":%.9g,\"ranges\":[",
        i ? "," : "", f.name, f.height, f.ascend, f.padding, f.distslope);
      for (int r = 0; r < f.numRanges; ++r) {
        const auto &range = f.ranges[r];
        std::fprintf(json, "%s[%d,%d]", r ? "," : "", range.start, range.end);
      }
      std::fprintf(json, "],\"glyphs\":{");
      std::set<int> emitted;
      bool first = true;
      for (int r = 0; r < f.numRanges; ++r) {
        for (int cp = f.ranges[r].start; cp < f.ranges[r].end; ++cp) {
          const AtlasChar *c = f.getChar(cp);
          if (!c || !emitted.insert(cp).second) continue;
          std::fprintf(json, "%s\"%d\":[%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%d,%d]",
            first ? "" : ",", cp, c->sx, c->sy, c->ex, c->ey, c->ox, c->oy, c->wx, c->pw, c->ph);
          first = false;
        }
      }
      std::fprintf(json, "}}");
    }
    std::fprintf(json, "]}\n");
    require(std::fclose(json) == 0, "Cannot write metadata dump");
    FILE *rgba = std::fopen((prefix + ".rgba").c_str(), "wb");
    require(rgba != nullptr, "Cannot open texture dump");
    const int format = flags & ZIM_FORMAT_MASK;
    require(format == ZIM_RGBA8888 || format == ZIM_RGBA4444, "Unsupported proof texture format");
    for (int p = 0; p < width[0] * height[0]; ++p) {
      uint8_t color[4];
      if (format == ZIM_RGBA8888) {
        for (int c = 0; c < 4; ++c) color[c] = pixels[0][p * 4 + c];
      } else {
        uint16_t value;
        std::memcpy(&value, pixels[0] + p * 2, 2);
        for (int c = 0; c < 4; ++c) color[c] = ((value >> (12 - c * 4)) & 15) * 17;
      }
      require(std::fwrite(color, 1, 4, rgba) == 4, "Cannot write texture dump");
    }
    require(std::fclose(rgba) == 0, "Cannot finish texture dump");
  }
  std::printf("{\"width\":%d,\"height\":%d,\"format\":%d,\"fonts\":%d,\"images\":%d,\"glyphRecords\":%zu}\n",
    width[0], height[0], flags & ZIM_FORMAT_MASK, atlas.num_fonts, atlas.num_images, glyphs);
  std::free(pixels[0]);
}
