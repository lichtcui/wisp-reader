// Offline TTS probe for HarmonyOS devices.
//
// This is intentionally a standalone CLI. It links against sherpa-onnx's C API
// but does not install, start, or modify the Source Reader application.

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <limits>
#include <sstream>
#include <string>
#include <vector>

#include "sherpa-onnx/c-api/c-api.h"

namespace {

struct Options {
  std::string family = "vits";
  std::string label = "vits";
  std::string text_id = "default";
  std::string model;
  std::string vocoder;
  std::string lexicon;
  std::string tokens;
  std::string voices;
  std::string lang;
  std::string data_dir;
  std::string dict_dir;
  std::string rule_fsts;
  std::string text;
  std::string output = "tts-probe.wav";
  int threads = 4;
  int sid = 0;
  int warmup = 2;
  int runs = 10;
  int max_num_sentences = 1;
  float speed = 1.0f;
  float silence_scale = 0.2f;
  float noise_scale = 0.667f;
  float noise_scale_w = 0.8f;
};

struct Metrics {
  double audio_sec = 0.0;
  double rtf = 0.0;
  double min = 0.0;
  double max = 0.0;
  double peak = 0.0;
  double rms = 0.0;
  double silence_ratio = 0.0;
  double clipping_ratio = 0.0;
  double longest_silence_ms = 0.0;
  double zcr = 0.0;
  int64_t nan_count = 0;
  int64_t inf_count = 0;
};

void Usage(const char* argv0) {
  std::cerr
      << "Usage: " << argv0 << " [options]\n"
      << "  --family vits|matcha|kokoro\n"
      << "  --label NAME --text-id ID --text UTF8 --output FILE\n"
      << "  --model FILE [--vocoder FILE] [--lexicon FILE] [--tokens FILE]\n"
      << "  [--voices FILE] [--lang CODE]\n"
      << "  --data-dir DIR --dict-dir DIR --rule-fsts F1,F2\n"
      << "  --threads N --sid N --warmup N --runs N\n"
      << "  --speed N --silence-scale N\n"
      << "  --noise-scale N --noise-scale-w N --max-num-sentences N\n";
}

bool ParseInt(const std::string& value, int* out) {
  char* end = nullptr;
  errno = 0;
  long parsed = std::strtol(value.c_str(), &end, 10);
  if (errno != 0 || end == value.c_str() || *end != '\0' ||
      parsed < std::numeric_limits<int>::min() ||
      parsed > std::numeric_limits<int>::max()) {
    return false;
  }
  *out = static_cast<int>(parsed);
  return true;
}

bool ParseFloat(const std::string& value, float* out) {
  char* end = nullptr;
  errno = 0;
  float parsed = std::strtof(value.c_str(), &end);
  if (errno != 0 || end == value.c_str() || *end != '\0' ||
      !std::isfinite(parsed)) {
    return false;
  }
  *out = parsed;
  return true;
}

bool ParseArgs(int argc, char** argv, Options* opt, std::string* error) {
  for (int i = 1; i < argc; ++i) {
    const std::string key = argv[i];
    if (key == "--help" || key == "-h") {
      Usage(argv[0]);
      std::exit(0);
    }
    if (i + 1 >= argc) {
      *error = "missing value for " + key;
      return false;
    }
    const std::string value = argv[++i];
    if (key == "--family") {
      opt->family = value;
    } else if (key == "--label") {
      opt->label = value;
    } else if (key == "--text-id") {
      opt->text_id = value;
    } else if (key == "--model") {
      opt->model = value;
    } else if (key == "--vocoder") {
      opt->vocoder = value;
    } else if (key == "--lexicon") {
      opt->lexicon = value;
    } else if (key == "--tokens") {
      opt->tokens = value;
    } else if (key == "--voices") {
      opt->voices = value;
    } else if (key == "--lang") {
      opt->lang = value;
    } else if (key == "--data-dir") {
      opt->data_dir = value;
    } else if (key == "--dict-dir") {
      opt->dict_dir = value;
    } else if (key == "--rule-fsts") {
      opt->rule_fsts = value;
    } else if (key == "--text") {
      opt->text = value;
    } else if (key == "--output") {
      opt->output = value;
    } else if (key == "--threads") {
      if (!ParseInt(value, &opt->threads)) {
        *error = "invalid integer for " + key;
        return false;
      }
    } else if (key == "--sid") {
      if (!ParseInt(value, &opt->sid)) {
        *error = "invalid integer for " + key;
        return false;
      }
    } else if (key == "--warmup") {
      if (!ParseInt(value, &opt->warmup)) {
        *error = "invalid integer for " + key;
        return false;
      }
    } else if (key == "--runs") {
      if (!ParseInt(value, &opt->runs)) {
        *error = "invalid integer for " + key;
        return false;
      }
    } else if (key == "--max-num-sentences") {
      if (!ParseInt(value, &opt->max_num_sentences)) {
        *error = "invalid integer for " + key;
        return false;
      }
    } else if (key == "--speed") {
      if (!ParseFloat(value, &opt->speed)) {
        *error = "invalid float for " + key;
        return false;
      }
    } else if (key == "--silence-scale") {
      if (!ParseFloat(value, &opt->silence_scale)) {
        *error = "invalid float for " + key;
        return false;
      }
    } else if (key == "--noise-scale") {
      if (!ParseFloat(value, &opt->noise_scale)) {
        *error = "invalid float for " + key;
        return false;
      }
    } else if (key == "--noise-scale-w") {
      if (!ParseFloat(value, &opt->noise_scale_w)) {
        *error = "invalid float for " + key;
        return false;
      }
    } else {
      *error = "unknown option " + key;
      return false;
    }
  }
  return true;
}

bool Validate(const Options& opt, std::string* error) {
  if (opt.family != "vits" && opt.family != "matcha" &&
      opt.family != "kokoro") {
    *error = "--family must be vits, matcha, or kokoro";
  } else if (opt.model.empty()) {
    *error = "--model is required";
  } else if (opt.tokens.empty()) {
    *error = "--tokens is required";
  } else if (opt.family == "matcha" && opt.vocoder.empty()) {
    *error = "--vocoder is required for matcha";
  } else if (opt.family == "kokoro" && opt.voices.empty()) {
    *error = "--voices is required for kokoro";
  } else if (opt.text.empty()) {
    *error = "--text is required";
  } else if (opt.output.empty()) {
    *error = "--output is required";
  } else if (opt.threads < 1) {
    *error = "--threads must be >= 1";
  } else if (opt.sid < 0) {
    *error = "--sid must be >= 0";
  } else if (opt.warmup < 0) {
    *error = "--warmup must be >= 0";
  } else if (opt.runs < 1) {
    *error = "--runs must be >= 1";
  } else if (opt.max_num_sentences < -1) {
    *error = "--max-num-sentences must be >= -1";
  } else if (opt.speed <= 0.0f) {
    *error = "--speed must be > 0";
  } else if (opt.silence_scale < 0.01f || opt.silence_scale > 10.0f) {
    *error = "--silence-scale must be in [0.01, 10]";
  } else {
    return true;
  }
  return false;
}

std::string JsonEscape(const std::string& value) {
  std::ostringstream out;
  for (unsigned char c : value) {
    switch (c) {
      case '"':
        out << "\\\"";
        break;
      case '\\':
        out << "\\\\";
        break;
      case '\b':
        out << "\\b";
        break;
      case '\f':
        out << "\\f";
        break;
      case '\n':
        out << "\\n";
        break;
      case '\r':
        out << "\\r";
        break;
      case '\t':
        out << "\\t";
        break;
      default:
        if (c < 0x20) {
          out << "\\u" << std::hex << std::setw(4) << std::setfill('0')
              << static_cast<int>(c) << std::dec;
        } else {
          out << static_cast<char>(c);
        }
    }
  }
  return out.str();
}

double MillisecondsSince(std::chrono::steady_clock::time_point start) {
  const auto elapsed = std::chrono::steady_clock::now() - start;
  return std::chrono::duration<double, std::milli>(elapsed).count();
}

struct RunResult {
  int index = 0;
  bool warmup = false;
  double wall_ms = 0.0;
  int sample_rate = 0;
  int sample_count = 0;
  Metrics metrics;
};

Metrics Measure(const float* samples, int n, int sample_rate, double wall_ms) {
  Metrics m;
  if (n <= 0 || sample_rate <= 0) {
    m.nan_count = n;
    return m;
  }

  double sum_sq = 0.0;
  double min_value = std::numeric_limits<double>::infinity();
  double max_value = -std::numeric_limits<double>::infinity();
  int64_t finite_count = 0;
  int64_t silent_count = 0;
  int64_t clip_count = 0;
  int64_t zcr_count = 0;
  int64_t current_silence = 0;
  int64_t longest_silence = 0;
  float previous = 0.0f;
  bool have_previous = false;

  for (int i = 0; i < n; ++i) {
    const float value = samples[i];
    if (std::isnan(value)) {
      ++m.nan_count;
      continue;
    }
    if (std::isinf(value)) {
      ++m.inf_count;
      continue;
    }

    ++finite_count;
    sum_sq += static_cast<double>(value) * static_cast<double>(value);
    min_value = std::min(min_value, static_cast<double>(value));
    max_value = std::max(max_value, static_cast<double>(value));

    if (std::fabs(value) < 1e-4f) {
      ++silent_count;
      ++current_silence;
      longest_silence = std::max(longest_silence, current_silence);
    } else {
      current_silence = 0;
    }
    if (std::fabs(value) >= 0.999f) {
      ++clip_count;
    }

    if (have_previous && ((previous < 0.0f && value >= 0.0f) ||
                          (previous >= 0.0f && value < 0.0f))) {
      ++zcr_count;
    }
    previous = value;
    have_previous = true;
  }

  m.audio_sec = static_cast<double>(n) / sample_rate;
  m.rtf = m.audio_sec > 0.0 ? (wall_ms / 1000.0) / m.audio_sec : 0.0;
  if (finite_count > 0) {
    m.min = min_value;
    m.max = max_value;
    m.peak = std::max(std::fabs(min_value), std::fabs(max_value));
    m.rms = std::sqrt(sum_sq / finite_count);
    m.silence_ratio = static_cast<double>(silent_count) / n;
    m.clipping_ratio = static_cast<double>(clip_count) / n;
    m.longest_silence_ms =
        static_cast<double>(longest_silence) * 1000.0 / sample_rate;
    m.zcr = static_cast<double>(zcr_count) / std::max<int64_t>(n - 1, 1);
  }
  return m;
}

void BuildConfig(const Options& opt, SherpaOnnxOfflineTtsConfig* config) {
  std::memset(config, 0, sizeof(*config));
  config->model.num_threads = opt.threads;
  config->model.debug = 0;
  config->model.provider = "cpu";
  config->max_num_sentences = opt.max_num_sentences;
  config->silence_scale = opt.silence_scale;

  if (!opt.rule_fsts.empty()) {
    config->rule_fsts = opt.rule_fsts.c_str();
  }

  if (opt.family == "vits") {
    config->model.vits.model = opt.model.c_str();
    config->model.vits.lexicon =
        opt.lexicon.empty() ? nullptr : opt.lexicon.c_str();
    config->model.vits.tokens = opt.tokens.c_str();
    config->model.vits.data_dir =
        opt.data_dir.empty() ? nullptr : opt.data_dir.c_str();
    config->model.vits.dict_dir =
        opt.dict_dir.empty() ? nullptr : opt.dict_dir.c_str();
    config->model.vits.noise_scale = opt.noise_scale;
    config->model.vits.noise_scale_w = opt.noise_scale_w;
    config->model.vits.length_scale = 1.0f;
  } else if (opt.family == "matcha") {
    config->model.matcha.acoustic_model = opt.model.c_str();
    config->model.matcha.vocoder = opt.vocoder.c_str();
    config->model.matcha.lexicon =
        opt.lexicon.empty() ? nullptr : opt.lexicon.c_str();
    config->model.matcha.tokens = opt.tokens.c_str();
    config->model.matcha.data_dir =
        opt.data_dir.empty() ? nullptr : opt.data_dir.c_str();
    config->model.matcha.dict_dir =
        opt.dict_dir.empty() ? nullptr : opt.dict_dir.c_str();
    config->model.matcha.noise_scale = opt.noise_scale;
    config->model.matcha.length_scale = 1.0f;
  } else {
    config->model.kokoro.model = opt.model.c_str();
    config->model.kokoro.voices = opt.voices.c_str();
    config->model.kokoro.tokens = opt.tokens.c_str();
    config->model.kokoro.data_dir =
        opt.data_dir.empty() ? nullptr : opt.data_dir.c_str();
    config->model.kokoro.length_scale = 1.0f;
    config->model.kokoro.dict_dir =
        opt.dict_dir.empty() ? nullptr : opt.dict_dir.c_str();
    config->model.kokoro.lexicon =
        opt.lexicon.empty() ? nullptr : opt.lexicon.c_str();
    config->model.kokoro.lang = opt.lang.empty() ? nullptr : opt.lang.c_str();
  }
}

void PrintRun(std::ostream& out, const Options& opt, const RunResult& result,
              double load_ms, int num_speakers, int model_sample_rate) {
  const Metrics& m = result.metrics;
  const bool finite = m.nan_count == 0 && m.inf_count == 0;
  out << std::fixed << std::setprecision(6)
      << "{\"event\":\"run\",\"schema\":1"
      << ",\"family\":\"" << JsonEscape(opt.family) << "\""
      << ",\"label\":\"" << JsonEscape(opt.label) << "\""
      << ",\"text_id\":\"" << JsonEscape(opt.text_id) << "\""
      << ",\"text_bytes\":" << opt.text.size()
      << ",\"threads\":" << opt.threads
      << ",\"sid\":" << opt.sid
      << ",\"speed\":" << opt.speed
      << ",\"silence_scale\":" << opt.silence_scale
      << ",\"max_num_sentences\":" << opt.max_num_sentences
      << ",\"run\":" << result.index
      << ",\"warmup\":" << (result.warmup ? "true" : "false")
      << ",\"load_ms\":" << load_ms
      << ",\"wall_ms\":" << result.wall_ms
      << ",\"sample_rate\":" << result.sample_rate
      << ",\"model_sample_rate\":" << model_sample_rate
      << ",\"num_speakers\":" << num_speakers
      << ",\"samples\":" << result.sample_count
      << ",\"audio_sec\":" << m.audio_sec
      << ",\"rtf\":" << m.rtf
      << ",\"finite\":" << (finite ? "true" : "false")
      << ",\"nan_count\":" << m.nan_count
      << ",\"inf_count\":" << m.inf_count
      << ",\"min\":" << m.min
      << ",\"max\":" << m.max
      << ",\"peak\":" << m.peak
      << ",\"rms\":" << m.rms
      << ",\"silence_ratio\":" << m.silence_ratio
      << ",\"clipping_ratio\":" << m.clipping_ratio
      << ",\"longest_silence_ms\":" << m.longest_silence_ms
      << ",\"zcr\":" << m.zcr
      << "}" << std::endl;
}

}  // namespace

int main(int argc, char** argv) {
  Options opt;
  std::string error;
  if (!ParseArgs(argc, argv, &opt, &error)) {
    std::cerr << "tts_probe: " << error << "\n";
    Usage(argv[0]);
    return 2;
  }
  if (!Validate(opt, &error)) {
    std::cerr << "tts_probe: " << error << "\n";
    return 2;
  }

  SherpaOnnxOfflineTtsConfig config;
  BuildConfig(opt, &config);

  const auto load_start = std::chrono::steady_clock::now();
  const SherpaOnnxOfflineTts* tts = SherpaOnnxCreateOfflineTts(&config);
  const double load_ms = MillisecondsSince(load_start);
  if (tts == nullptr) {
    std::cerr << "tts_probe: SherpaOnnxCreateOfflineTts failed\n";
    return 3;
  }

  const int model_sample_rate = SherpaOnnxOfflineTtsSampleRate(tts);
  const int num_speakers = SherpaOnnxOfflineTtsNumSpeakers(tts);
  if (model_sample_rate <= 0) {
    std::cerr << "tts_probe: invalid model sample rate\n";
    SherpaOnnxDestroyOfflineTts(tts);
    return 3;
  }

  SherpaOnnxGenerationConfig generation;
  std::memset(&generation, 0, sizeof(generation));
  generation.speed = opt.speed;
  generation.sid = opt.sid;
  generation.silence_scale = opt.silence_scale;

  std::vector<float> last_samples;
  int last_sample_rate = 0;
  int recorded_runs = 0;
  const int total_runs = opt.warmup + opt.runs;

  for (int i = 1; i <= total_runs; ++i) {
    const bool warmup = i <= opt.warmup;
    const auto start = std::chrono::steady_clock::now();
    const SherpaOnnxGeneratedAudio* audio =
        SherpaOnnxOfflineTtsGenerateWithConfig(tts, opt.text.c_str(),
                                               &generation, nullptr, nullptr);
    const double wall_ms = MillisecondsSince(start);
    if (audio == nullptr || audio->samples == nullptr || audio->n <= 0 ||
        audio->sample_rate <= 0) {
      std::cerr << "tts_probe: generation failed at run " << i << "\n";
      if (audio != nullptr) {
        SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio);
      }
      SherpaOnnxDestroyOfflineTts(tts);
      return 4;
    }

    RunResult result;
    result.index = i;
    result.warmup = warmup;
    result.wall_ms = wall_ms;
    result.sample_rate = audio->sample_rate;
    result.sample_count = audio->n;
    result.metrics =
        Measure(audio->samples, audio->n, audio->sample_rate, wall_ms);
    PrintRun(std::cout, opt, result, load_ms, num_speakers, model_sample_rate);

    if (!warmup) {
      last_samples.assign(audio->samples, audio->samples + audio->n);
      last_sample_rate = audio->sample_rate;
      ++recorded_runs;
    }
    SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio);
  }

  if (last_samples.empty() || last_sample_rate <= 0) {
    std::cerr << "tts_probe: no measured audio to write\n";
    SherpaOnnxDestroyOfflineTts(tts);
    return 4;
  }
  if (!SherpaOnnxWriteWave(last_samples.data(),
                           static_cast<int32_t>(last_samples.size()),
                           last_sample_rate, opt.output.c_str())) {
    std::cerr << "tts_probe: failed to write " << opt.output << "\n";
    SherpaOnnxDestroyOfflineTts(tts);
    return 5;
  }

  std::cout << std::fixed << std::setprecision(3)
            << "{\"event\":\"complete\",\"schema\":1"
            << ",\"family\":\"" << JsonEscape(opt.family) << "\""
            << ",\"label\":\"" << JsonEscape(opt.label) << "\""
            << ",\"text_id\":\"" << JsonEscape(opt.text_id) << "\""
            << ",\"threads\":" << opt.threads
            << ",\"sid\":" << opt.sid
            << ",\"warmup_runs\":" << opt.warmup
            << ",\"measured_runs\":" << recorded_runs
            << ",\"load_ms\":" << load_ms
            << ",\"model_sample_rate\":" << model_sample_rate
            << ",\"num_speakers\":" << num_speakers
            << ",\"output\":\"" << JsonEscape(opt.output) << "\""
            << "}" << std::endl;

  SherpaOnnxDestroyOfflineTts(tts);
  return 0;
}
