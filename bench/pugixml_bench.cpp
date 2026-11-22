#define _POSIX_C_SOURCE 199309L
#include <pugixml.hpp>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <sys/resource.h>

static double now_sec() {
    timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static long rss_kb() {
    rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    return ru.ru_maxrss;
}

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    FILE *file = fopen(argv[1], "rb");
    if (!file) return 2;
    fseek(file, 0, SEEK_END);
    long size = ftell(file);
    fseek(file, 0, SEEK_SET);
    char *data = static_cast<char *>(malloc(static_cast<size_t>(size)));
    if (!data) return 2;
    if (fread(data, 1, static_cast<size_t>(size), file) != static_cast<size_t>(size)) return 2;
    fclose(file);

    const int iterations = 6;
    double best = 1e30;
    for (int i = 0; i < iterations; i++) {
        double start = now_sec();
        pugi::xml_document doc;
        pugi::xml_parse_result result = doc.load_buffer(data, static_cast<size_t>(size));
        if (!result) {
            std::fprintf(stderr, "pugixml: %s\n", result.description());
            return 1;
        }
        double elapsed = now_sec() - start;
        if (i != 0 && elapsed < best) best = elapsed;
    }
    double mb = static_cast<double>(size) / (1024.0 * 1024.0);
    std::printf("pugixml,dom,%.2f,%ld\n", mb / best, rss_kb());
    free(data);
    return 0;
}
