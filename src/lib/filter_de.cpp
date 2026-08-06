// filter_de: stream DE output.txt and write filtered.{up,down}.json
//
// Preferred (legacy + v8 annot paths):
//   filter_de --file OUTPUT_TXT FDR_CUTOFF FC_CUTOFF
//   -> writes filtered.up.json / filtered.down.json next to OUTPUT_TXT
//   -> prints "UP_COUNT DOWN_COUNT" on stdout
//
// Batch (one process, many files; paths on stdin):
//   filter_de --batch FDR_CUTOFF FC_CUTOFF < paths.txt
//   -> for each path: write filtered json; print "PATH\tUP\tDOWN"
//
// Legacy:
//   filter_de PROJECT_PATH FDR_CUTOFF FC_CUTOFF MODE USER_ID RUN_ID
//   MODE=de_results filters PROJECT/de/RUN_ID/output.txt
//
// Compile (no Boost):
//   g++ -O2 -std=c++17 -o filter_de filter_de.cpp

#include <cmath>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace {

double parse_double(const std::string& str) {
  std::stringstream ss(str);
  double d = 0.0;
  ss >> d;
  return d;
}

std::string join_ints(const std::vector<int>& v) {
  std::ostringstream ss;
  for (size_t i = 0; i < v.size(); ++i) {
    if (i != 0) ss << ',';
    ss << v[i];
  }
  return ss.str();
}

std::string dirname_of(const std::string& path) {
  const auto pos = path.find_last_of('/');
  if (pos == std::string::npos) return ".";
  if (pos == 0) return "/";
  return path.substr(0, pos);
}

std::string join_path(const std::string& a, const std::string& b) {
  if (a.empty()) return b;
  if (a.back() == '/') return a + b;
  return a + "/" + b;
}

// Columns (0-based): 5 = logFC, 7 = FDR. Same contract as the Ruby path / historical filter_de.
bool filter_output_txt(const std::string& input_filepath,
                       double fdr_cutoff,
                       double logfc_cutoff,
                       std::vector<int>& vec_up,
                       std::vector<int>& vec_down) {
  std::ifstream fin(input_filepath.c_str());
  if (!fin) return false;

  std::string line;
  int i = 0;
  while (std::getline(fin, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();

    // Extract fields 5 and 7 without storing all columns.
    int col = 0;
    std::size_t start = 0;
    std::string col5;
    std::string col7;
    bool have5 = false;
    bool have7 = false;
    for (std::size_t pos = 0; pos <= line.size(); ++pos) {
      const bool at_end = (pos == line.size());
      const bool is_tab = (!at_end && line[pos] == '\t');
      if (!at_end && !is_tab) continue;

      if (col == 5) {
        col5 = line.substr(start, pos - start);
        have5 = true;
      } else if (col == 7) {
        col7 = line.substr(start, pos - start);
        have7 = true;
        break;
      }
      col += 1;
      start = pos + 1;
    }

    if (have5 && have7 && col5 != "NA" && col7 != "NA" && !col5.empty() && !col7.empty()) {
      const double fdr = parse_double(col7);
      const double logfc = parse_double(col5);
      if (fdr <= fdr_cutoff) {
        if (logfc >= logfc_cutoff) {
          vec_up.push_back(i);
        } else if (logfc <= -logfc_cutoff) {
          vec_down.push_back(i);
        }
      }
    }
    ++i;
  }
  return true;
}

bool write_filtered_json(const std::string& dir,
                         const std::vector<int>& vec_up,
                         const std::vector<int>& vec_down) {
  const std::string up_path = join_path(dir, "filtered.up.json");
  const std::string down_path = join_path(dir, "filtered.down.json");

  std::ofstream fout_up(up_path.c_str());
  std::ofstream fout_down(down_path.c_str());
  if (!fout_up || !fout_down) return false;

  fout_up << '[' << join_ints(vec_up) << ']';
  fout_down << '[' << join_ints(vec_down) << ']';
  return true;
}

int run_file_mode(const std::string& input_filepath, double fdr_cutoff, double fc_cutoff) {
  if (fc_cutoff <= 0.0) fc_cutoff = 1.0;
  const double logfc_cutoff = std::log2(fc_cutoff);

  std::vector<int> vec_up;
  std::vector<int> vec_down;
  if (!filter_output_txt(input_filepath, fdr_cutoff, logfc_cutoff, vec_up, vec_down)) {
    std::cerr << "filter_de: cannot open " << input_filepath << "\n";
    return 1;
  }

  const std::string dir = dirname_of(input_filepath);
  if (!write_filtered_json(dir, vec_up, vec_down)) {
    std::cerr << "filter_de: cannot write filtered json in " << dir << "\n";
    return 1;
  }

  std::cout << vec_up.size() << ' ' << vec_down.size() << '\n';
  return 0;
}

int run_legacy_mode(int argc, char** argv) {
  if (argc < 7) {
    std::cerr << "Usage:\n"
              << "  filter_de --file OUTPUT_TXT FDR_CUTOFF FC_CUTOFF\n"
              << "  filter_de PROJECT_PATH FDR_CUTOFF FC_CUTOFF MODE USER_ID RUN_ID\n";
    return 2;
  }

  const std::string project_filepath = argv[1];
  const double fdr_cutoff = parse_double(argv[2]);
  double fc_cutoff = parse_double(argv[3]);
  if (fc_cutoff <= 0.0) fc_cutoff = 1.0;
  const double logfc_cutoff = std::log2(fc_cutoff);
  const std::string mode = argv[4];
  const std::string user_id = argv[5];
  const std::string run_id = argv[6];

  const std::string input_filepath =
      join_path(join_path(join_path(project_filepath, "de"), run_id), "output.txt");
  const std::string dir = dirname_of(input_filepath);
  const std::string tmp_dir = join_path(project_filepath, "tmp");

  std::vector<int> vec_up;
  std::vector<int> vec_down;
  if (!filter_output_txt(input_filepath, fdr_cutoff, logfc_cutoff, vec_up, vec_down)) {
    std::cerr << "filter_de: cannot open " << input_filepath << "\n";
    return 1;
  }

  if (mode == "de_results") {
    if (!write_filtered_json(dir, vec_up, vec_down)) {
      std::cerr << "filter_de: cannot write filtered json in " << dir << "\n";
      return 1;
    }
  } else {
    // Legacy GE form side files (row indices + gene ids). Kept for old callers.
    {
      const std::string filtered_path =
          join_path(tmp_dir, user_id + "_" + run_id + "_filtered.json");
      std::ofstream fout(filtered_path.c_str());
      if (!fout) return 1;
      fout << "{\"down\" : [" << join_ints(vec_down) << "], \"up\" : ["
           << join_ints(vec_up) << "]}";
    }

    std::vector<int> vec_up_ids;
    std::vector<int> vec_down_ids;
    {
      std::ifstream fin(input_filepath.c_str());
      std::string line;
      while (std::getline(fin, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        int col = 0;
        std::size_t start = 0;
        std::string col0;
        std::string col5;
        std::string col7;
        for (std::size_t pos = 0; pos <= line.size(); ++pos) {
          const bool at_end = (pos == line.size());
          const bool is_tab = (!at_end && line[pos] == '\t');
          if (!at_end && !is_tab) continue;
          if (col == 0) col0 = line.substr(start, pos - start);
          else if (col == 5) col5 = line.substr(start, pos - start);
          else if (col == 7) {
            col7 = line.substr(start, pos - start);
            break;
          }
          col += 1;
          start = pos + 1;
        }
        if (!col0.empty() && col5 != "NA" && col7 != "NA" && !col5.empty() && !col7.empty()) {
          const double fdr = parse_double(col7);
          const double logfc = parse_double(col5);
          if (fdr <= fdr_cutoff) {
            if (logfc >= logfc_cutoff) vec_up_ids.push_back(static_cast<int>(parse_double(col0)));
            else if (logfc <= -logfc_cutoff) vec_down_ids.push_back(static_cast<int>(parse_double(col0)));
          }
        }
      }
    }

    {
      const std::string ids_path = join_path(
          tmp_dir,
          user_id + "_" + run_id + "_" + argv[3] + "_" + argv[2] + "_filtered_ids.json");
      std::ofstream fout2(ids_path.c_str());
      if (!fout2) return 1;
      fout2 << "{\"down\" : [" << join_ints(vec_down_ids) << "], \"up\" : ["
            << join_ints(vec_up_ids) << "]}";
    }
  }

  // Legacy append of per-run counts into a shared stats file.
  {
    const std::string stats_name =
        (mode == "de_results") ? (user_id + "_de_filtered_stats.txt")
                               : (user_id + "_ge_form_filtered_stats.txt");
    const std::string filtered_stats_path = join_path(tmp_dir, stats_name);
    std::ofstream filtered_stats(filtered_stats_path.c_str(), std::ios_base::app);
    if (filtered_stats) {
      filtered_stats << run_id << "\t" << vec_up.size() << "\t" << vec_down.size() << "\n";
    }
  }

  std::cout << vec_up.size() << ' ' << vec_down.size() << '\n';
  return 0;
}

}  // namespace

int run_batch_mode(double fdr_cutoff, double fc_cutoff) {
  if (fc_cutoff <= 0.0) fc_cutoff = 1.0;
  const double logfc_cutoff = std::log2(fc_cutoff);

  std::string input_filepath;
  int failures = 0;
  while (std::getline(std::cin, input_filepath)) {
    if (!input_filepath.empty() && input_filepath.back() == '\r') input_filepath.pop_back();
    if (input_filepath.empty()) continue;

    std::vector<int> vec_up;
    std::vector<int> vec_down;
    if (!filter_output_txt(input_filepath, fdr_cutoff, logfc_cutoff, vec_up, vec_down)) {
      std::cerr << "filter_de: cannot open " << input_filepath << "\n";
      ++failures;
      continue;
    }

    const std::string dir = dirname_of(input_filepath);
    if (!write_filtered_json(dir, vec_up, vec_down)) {
      std::cerr << "filter_de: cannot write filtered json in " << dir << "\n";
      ++failures;
      continue;
    }

    std::cout << input_filepath << '\t' << vec_up.size() << '\t' << vec_down.size() << '\n';
  }
  return failures > 0 ? 1 : 0;
}

int main(int argc, char** argv) {
  if (argc >= 2 && std::string(argv[1]) == "--file") {
    if (argc < 5) {
      std::cerr << "Usage: filter_de --file OUTPUT_TXT FDR_CUTOFF FC_CUTOFF\n";
      return 2;
    }
    const std::string input_filepath = argv[2];
    const double fdr_cutoff = parse_double(argv[3]);
    const double fc_cutoff = parse_double(argv[4]);
    return run_file_mode(input_filepath, fdr_cutoff, fc_cutoff);
  }
  if (argc >= 2 && std::string(argv[1]) == "--batch") {
    if (argc < 4) {
      std::cerr << "Usage: filter_de --batch FDR_CUTOFF FC_CUTOFF < paths.txt\n";
      return 2;
    }
    const double fdr_cutoff = parse_double(argv[2]);
    const double fc_cutoff = parse_double(argv[3]);
    return run_batch_mode(fdr_cutoff, fc_cutoff);
  }
  return run_legacy_mode(argc, argv);
}
