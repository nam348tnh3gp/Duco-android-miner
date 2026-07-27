#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <sys/resource.h>
#include <netinet/in.h>
#include <netdb.h>
#include <stdarg.h>

#include "DSHA1.h"

// ==================== LOG RING BUFFER ====================
#define MAX_LOG_LINES 200
#define MAX_LOG_LEN  512

static char *g_log_lines[MAX_LOG_LINES];
static int g_log_head = 0;
static int g_log_tail = 0;
static int g_log_count = 0;
static pthread_mutex_t g_log_mutex = PTHREAD_MUTEX_INITIALIZER;

static void add_log(const char *msg) {
    pthread_mutex_lock(&g_log_mutex);
    if (g_log_count < MAX_LOG_LINES) {
        g_log_lines[g_log_tail] = strdup(msg);
        g_log_tail = (g_log_tail + 1) % MAX_LOG_LINES;
        g_log_count++;
    } else {
        free(g_log_lines[g_log_head]);
        g_log_lines[g_log_head] = strdup(msg);
        g_log_head = (g_log_head + 1) % MAX_LOG_LINES;
        g_log_tail = (g_log_head + g_log_count) % MAX_LOG_LINES;
    }
    pthread_mutex_unlock(&g_log_mutex);
}

void get_logs(char *buffer, int buffer_size) {
    pthread_mutex_lock(&g_log_mutex);
    buffer[0] = '\0';
    int idx = g_log_head;
    for (int i = 0; i < g_log_count; i++) {
        if (g_log_lines[idx]) {
            strncat(buffer, g_log_lines[idx], buffer_size - strlen(buffer) - 1);
            strncat(buffer, "\n", buffer_size - strlen(buffer) - 1);
        }
        idx = (idx + 1) % MAX_LOG_LINES;
    }
    pthread_mutex_unlock(&g_log_mutex);
}

// ==================== CẤU HÌNH ====================
#define MAX_THREADS 32

typedef struct {
    char username[64];
    char mining_key[64];
    char difficulty[16];
    char rig_identifier[64];
    int thread_count;
    int nice_level;
    char pool_ip[64];
    int pool_port;
    int intensity;
    int single_id;
} Config;

typedef struct {
    char name[64];
    char ip[64];
    int port;
} PoolInfo;

static Config g_config;
static PoolInfo g_pool_info = {0};
static volatile int g_running = 0;
static pthread_t *g_threads = NULL;
static int g_thread_count = 0;

static double g_hashrates[MAX_THREADS];
static pthread_mutex_t g_hash_mutex = PTHREAD_MUTEX_INITIALIZER;

// ==================== MÀU ANSI VÀ SYMBOLS ====================
#define COLOR_RESET   "\033[0m"
#define COLOR_GREEN   "\033[32m"
#define COLOR_RED     "\033[31m"
#define COLOR_YELLOW  "\033[33m"
#define COLOR_BLUE    "\033[34m"
#define COLOR_CYAN    "\033[36m"
#define COLOR_MAGENTA "\033[35m"
#define COLOR_WHITE   "\033[37m"
#define COLOR_BOLD    "\033[1m"
#define COLOR_DIM     "\033[2m"

#define BLOCK_SYMBOL  " ‖ "
#define PICK_SYMBOL   " ⛏"
#define COG_SYMBOL    " ⚙"

// ==================== TCP & SHA1 ====================
int tcp_connect(const char *ip, int port) {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return -1;
    struct sockaddr_in addr;
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    inet_pton(AF_INET, ip, &addr.sin_addr);
    if (connect(sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        close(sock);
        return -1;
    }
    return sock;
}

int send_tcp(int sock, const char *data) {
    ssize_t len = strlen(data);
    ssize_t sent = send(sock, data, len, 0);
    return sent == len ? 1 : 0;
}

int recv_line(int sock, char *buffer, size_t size) {
    size_t i = 0;
    char c;
    while (i < size - 1 && recv(sock, &c, 1, 0) > 0) {
        if (c == '\n') {
            buffer[i] = '\0';
            return 1;
        }
        buffer[i++] = c;
    }
    buffer[i] = '\0';
    return i > 0 ? 1 : 0;
}

static inline void sha1_string(const char *input, unsigned char *output) {
    DSHA1_CTX ctx;
    dsha1_init(&ctx);
    dsha1_write(&ctx, (const unsigned char*)input, strlen(input));
    dsha1_finalize(&ctx, output);
}

typedef struct {
    char base[256];
    unsigned char target[20];
    int diff;
} Job;

// ==================== HELPER FUNCTIONS ====================
static void get_timestamp(char *buf, size_t size) {
    time_t now = time(NULL);
    struct tm *tm = localtime(&now);
    strftime(buf, size, "%H:%M:%S", tm);
}

static inline double calc_eff(int intensity) {
    if (intensity >= 90 && intensity < 99) return 0.005;
    if (intensity >= 70 && intensity < 90) return 0.1;
    if (intensity >= 50 && intensity < 70) return 0.8;
    if (intensity >= 30 && intensity < 50) return 1.8;
    if (intensity >= 1  && intensity < 30) return 3.0;
    return 0.0;
}

static const char* format_hashrate(double h) {
    static char buf[64];
    if (h >= 1e9) snprintf(buf, sizeof(buf), "%.2f GH/s", h/1e9);
    else if (h >= 1e6) snprintf(buf, sizeof(buf), "%.2f MH/s", h/1e6);
    else if (h >= 1e3) snprintf(buf, sizeof(buf), "%.2f kH/s", h/1e3);
    else snprintf(buf, sizeof(buf), "%.2f H/s", h);
    return buf;
}

static const char* get_greeting() {
    time_t now = time(NULL);
    struct tm *tm = localtime(&now);
    int hour = tm->tm_hour;
    if (hour < 12) return "Good morning";
    if (hour == 12) return "Good noon";
    if (hour > 12 && hour < 18) return "Good afternoon";
    return "Good evening";
}

static void get_cpu_info(char *buffer, size_t size) {
    FILE *fp = fopen("/proc/cpuinfo", "r");
    if (!fp) {
        snprintf(buffer, size, "Unknown CPU");
        return;
    }
    
    char line[256];
    char model[128] = "Unknown";
    char arch[64] = "Unknown";
    int cores = 0;
    int has_arch = 0;
    
    while (fgets(line, sizeof(line), fp)) {
        if (strncmp(line, "processor", 9) == 0) cores++;
        if (strncmp(line, "Processor", 9) == 0 || strncmp(line, "Hardware", 8) == 0) {
            char *value = strchr(line, ':');
            if (value) {
                value += 2;
                value[strcspn(value, "\n")] = 0;
                if (strcmp(model, "Unknown") == 0 || strncmp(line, "Processor", 9) == 0) {
                    strncpy(model, value, sizeof(model)-1);
                    model[sizeof(model)-1] = '\0';
                }
            }
        }
        if (strncmp(line, "CPU architecture", 17) == 0) {
            char *value = strchr(line, ':');
            if (value) {
                value += 2;
                value[strcspn(value, "\n")] = 0;
                int arch_num = atoi(value);
                if (arch_num == 8) strcpy(arch, "aarch64");
                else if (arch_num == 7) strcpy(arch, "armv7l");
                else if (arch_num == 6) strcpy(arch, "armv6l");
                else strncpy(arch, value, sizeof(arch)-1);
                arch[sizeof(arch)-1] = '\0';
                has_arch = 1;
            }
        }
    }
    fclose(fp);
    
    if (!has_arch) {
#ifdef __aarch64__
        strcpy(arch, "aarch64");
#elif defined(__arm__)
        strcpy(arch, "armv7l");
#elif defined(__i386__)
        strcpy(arch, "x86");
#elif defined(__x86_64__)
        strcpy(arch, "x86_64");
#else
        strcpy(arch, "Unknown");
#endif
    }
    
    if (cores == 0) {
        cores = sysconf(_SC_NPROCESSORS_CONF);
        if (cores <= 0) cores = 1;
    }
    
    if (strcmp(model, "Unknown") == 0) {
        snprintf(buffer, size, "%dx threads %s", cores, arch);
    } else {
        snprintf(buffer, size, "%dx threads %s (%s)", cores, arch, model);
    }
}

// ==================== LOGGING GIỐNG PYTHON ====================
static void log_general(const char *prefix, const char *color, const char *fmt, ...) {
    char ts[16];
    get_timestamp(ts, sizeof(ts));
    char msg[512];
    va_list args;
    va_start(args, fmt);
    vsnprintf(msg, sizeof(msg), fmt, args);
    va_end(args);
    
    char buffer[1024];
    snprintf(buffer, sizeof(buffer), "%s %s%s%s %s", ts, color ? color : "", prefix, color ? COLOR_RESET : "", msg);
    add_log(buffer);
}

#define log_info(prefix, fmt, ...)   log_general(prefix, COLOR_BLUE, fmt, ##__VA_ARGS__)
#define log_success(prefix, fmt, ...) log_general(prefix, COLOR_GREEN, fmt, ##__VA_ARGS__)
#define log_warning(prefix, fmt, ...) log_general(prefix, COLOR_YELLOW, fmt, ##__VA_ARGS__)
#define log_error(prefix, fmt, ...)   log_general(prefix, COLOR_RED, fmt, ##__VA_ARGS__)

static void log_share(int id, const char *type, int accept, int reject,
                      double thread_hashrate, double total_hashrate,
                      double computetime, int diff, double ping, const char *reject_cause) {
    char ts[16];
    get_timestamp(ts, sizeof(ts));
    const char *color, *status;
    
    if (strcmp(type, "accept") == 0) {
        color = COLOR_GREEN;
        status = "Accepted";
    } else if (strcmp(type, "block") == 0) {
        color = COLOR_YELLOW;
        status = "Block found";
    } else {
        color = COLOR_RED;
        status = "Rejected";
    }
    
    int total = accept + reject;
    int pct = (total > 0) ? (accept * 100 / total) : 0;
    
    char buffer[1024];
    if (strcmp(type, "reject") == 0 && reject_cause) {
        snprintf(buffer, sizeof(buffer),
                 "%s %s|cpu%d|%s %s" PICK_SYMBOL " %s(%s) %d/%d (%d%%) ∙ %.1fs ∙ %s (%s total) " COG_SYMBOL " diff %d ∙ ping %.0fms",
                 ts, COLOR_BOLD, id, COLOR_RESET,
                 color, status, reject_cause,
                 accept, total, pct,
                 computetime,
                 format_hashrate(thread_hashrate),
                 format_hashrate(total_hashrate),
                 diff, ping);
    } else {
        snprintf(buffer, sizeof(buffer),
                 "%s %s|cpu%d|%s %s" PICK_SYMBOL " %s %d/%d (%d%%) ∙ %.1fs ∙ %s (%s total) " COG_SYMBOL " diff %d ∙ ping %.0fms",
                 ts, COLOR_BOLD, id, COLOR_RESET,
                 color, status,
                 accept, total, pct,
                 computetime,
                 format_hashrate(thread_hashrate),
                 format_hashrate(total_hashrate),
                 diff, ping);
    }
    add_log(buffer);
}

// ====== BANNER MỚI: Flutter DUCO Miner v1.0.0 ======
static void log_startup_info(const char *username, const char *difficulty, const char *rig) {
    char cpu_info[256];
    get_cpu_info(cpu_info, sizeof(cpu_info));
    char buffer[512];
    
    add_log("========================================================================");
    snprintf(buffer, sizeof(buffer), "%s" COLOR_YELLOW BLOCK_SYMBOL COLOR_BOLD 
             "Flutter DUCO Miner v1.0.0" 
             COLOR_MAGENTA " (1.0.0) " COLOR_RESET "2024-2025", COLOR_YELLOW);
    add_log(buffer);
    snprintf(buffer, sizeof(buffer), "%s" COLOR_YELLOW BLOCK_SYMBOL COLOR_RESET 
             "https://github.com/your-repo/flutter-duco-miner", COLOR_YELLOW);
    add_log(buffer);
    snprintf(buffer, sizeof(buffer), "%s" COLOR_YELLOW BLOCK_SYMBOL COLOR_RESET 
             "CPU: " COLOR_BOLD "%s", COLOR_YELLOW, cpu_info);
    add_log(buffer);
    snprintf(buffer, sizeof(buffer), "%s" COLOR_YELLOW BLOCK_SYMBOL COLOR_RESET 
             "Donation level: " COLOR_BOLD "0", COLOR_YELLOW);
    add_log(buffer);
    snprintf(buffer, sizeof(buffer), "%s" COLOR_YELLOW BLOCK_SYMBOL COLOR_RESET 
             "Algorithm: " COLOR_BOLD "DUCO-S1" COLOR_RESET COG_SYMBOL " diff: %s", 
             COLOR_YELLOW, difficulty);
    add_log(buffer);
    if (rig && strcmp(rig, "None") != 0) {
        snprintf(buffer, sizeof(buffer), "%s" COLOR_YELLOW BLOCK_SYMBOL COLOR_RESET 
                 "Rig identifier: " COLOR_BOLD "%s", COLOR_YELLOW, rig);
        add_log(buffer);
    }
    // Config path mới
    snprintf(buffer, sizeof(buffer), "%s" COLOR_YELLOW BLOCK_SYMBOL COLOR_RESET 
             "Using config: " COLOR_BOLD "Flutter DUCO Miner/Settings.cfg", COLOR_YELLOW);
    add_log(buffer);
    snprintf(buffer, sizeof(buffer), "%s" COLOR_YELLOW BLOCK_SYMBOL COLOR_RESET 
             "%s, " COLOR_BOLD "%s" COLOR_RESET "!", COLOR_YELLOW, get_greeting(), username);
    add_log(buffer);
    add_log("========================================================================");
}

// ==================== WORKER THREAD ====================
void *worker_thread(void *arg) {
    int id = *(int*)arg;
    double eff = calc_eff(g_config.intensity);
    int is_first_connect = 1;
    char msg[128];
    
    while (g_running) {
        if (id == 0 && is_first_connect) {
            log_info("|net0|", "Connecting to " COLOR_BOLD "%s" COLOR_RESET " (%s:%d)...",
                     g_pool_info.name, g_config.pool_ip, g_config.pool_port);
        }
        
        int sock = tcp_connect(g_config.pool_ip, g_config.pool_port);
        if (sock < 0) {
            log_error("|net0|", "Connection failed, retry in 5s");
            sleep(5);
            continue;
        }
        
        char server_version[128];
        if (recv_line(sock, server_version, sizeof(server_version))) {
            if (id == 0 && is_first_connect) {
                log_success("|net0|", "Connected to " COLOR_BOLD "%s" COLOR_RESET " (v" COLOR_BOLD "%s" COLOR_RESET ")",
                            g_pool_info.name, server_version);
                
                float ver = atof(server_version);
                if (ver > 4.3) {
                    log_warning("|net0|", "Outdated miner (v" COLOR_BOLD "4.3" COLOR_RESET ") - Server is on v" COLOR_BOLD "%.1f" COLOR_RESET, ver);
                    sleep(5);
                }
                
                send_tcp(sock, "MOTD\n");
                char motd[512];
                if (recv_line(sock, motd, sizeof(motd))) {
                    char formatted_motd[1024] = "";
                    char *token = strtok(motd, "\n");
                    while (token != NULL) {
                        if (strlen(formatted_motd) > 0) strcat(formatted_motd, "\n\t\t");
                        strcat(formatted_motd, token);
                        token = strtok(NULL, "\n");
                    }
                    if (strlen(formatted_motd) > 0) {
                        log_info("|net0|", "MOTD:\n\t\t%s", formatted_motd);
                    }
                }
                is_first_connect = 0;
            }
        }
        
        int accepted = 0, rejected = 0;
        while (g_running) {
            char req[256];
            snprintf(req, sizeof(req), "JOB,%s,%s,%s,\n",
                     g_config.username, g_config.difficulty, g_config.mining_key);
            if (!send_tcp(sock, req)) {
                log_error("|net0|", "Send request failed");
                break;
            }
            
            char jobline[1024];
            if (!recv_line(sock, jobline, sizeof(jobline))) {
                log_error("|net0|", "No job received");
                break;
            }
            
            char *base = strtok(jobline, ",");
            char *target_hex = strtok(NULL, ",");
            char *diff_str = strtok(NULL, ",");
            if (!base || !target_hex || !diff_str) {
                log_warning("|net0|", "Bad job: %s", jobline);
                continue;
            }
            
            Job job;
            strncpy(job.base, base, sizeof(job.base)-1);
            job.base[sizeof(job.base)-1] = '\0';
            if (strlen(target_hex) != 40) continue;
            for (int i=0; i<20; i++) sscanf(target_hex + i*2, "%2hhx", &job.target[i]);
            job.diff = atoi(diff_str);
            
            struct timespec start, end;
            clock_gettime(CLOCK_MONOTONIC, &start);
            char nonce_str[16];
            unsigned char hash[20];
            char buffer[512];
            int base_len = strlen(job.base);
            memcpy(buffer, job.base, base_len);
            long long max_nonce = job.diff * 100;
            long long found_nonce = -1;
            
            for (long long nonce = 0; nonce <= max_nonce; nonce++) {
                if (nonce < 10) {
                    buffer[base_len] = '0' + nonce;
                    buffer[base_len + 1] = '\0';
                } else if (nonce < 100) {
                    buffer[base_len] = '0' + (nonce / 10);
                    buffer[base_len + 1] = '0' + (nonce % 10);
                    buffer[base_len + 2] = '\0';
                } else {
                    sprintf(nonce_str, "%lld", nonce);
                    int nonce_len = strlen(nonce_str);
                    memcpy(buffer + base_len, nonce_str, nonce_len);
                    buffer[base_len + nonce_len] = '\0';
                }
                sha1_string(buffer, hash);
                if (memcmp(hash, job.target, 20) == 0) {
                    found_nonce = nonce;
                    break;
                }
                if (eff > 0 && (nonce % 5000 == 0)) {
                    usleep((useconds_t)(eff / 100 * 1000000));
                }
            }
            
            clock_gettime(CLOCK_MONOTONIC, &end);
            double elapsed_ms = (end.tv_sec - start.tv_sec) * 1000.0 +
                                (end.tv_nsec - start.tv_nsec) / 1e6;
            
            if (found_nonce >= 0) {
                double hashrate = (found_nonce * 1000.0) / elapsed_ms;
                
                pthread_mutex_lock(&g_hash_mutex);
                g_hashrates[id] = hashrate;
                double total_hashrate = 0;
                for (int i = 0; i < g_thread_count; i++) total_hashrate += g_hashrates[i];
                pthread_mutex_unlock(&g_hash_mutex);
                
                // ====== TÊN GỬI LÊN SERVER: FlutterMiner (giữ nguyên code gốc) ======
                char result[256];
                snprintf(result, sizeof(result),
                         "%lld,%.2f,FlutterMiner,%s,,%d\n",
                         found_nonce, hashrate, g_config.rig_identifier, g_config.single_id);
                
                if (!send_tcp(sock, result)) {
                    log_error("|net0|", "Send result failed");
                    break;
                }
                
                char feedback[128];
                if (!recv_line(sock, feedback, sizeof(feedback))) {
                    log_error("|net0|", "No feedback");
                    break;
                }
                
                double ping = 0.0;
                if (strcmp(feedback, "GOOD") == 0) {
                    accepted++;
                    log_share(id, "accept", accepted, rejected, hashrate, total_hashrate,
                              elapsed_ms/1000.0, job.diff, ping, NULL);
                } else if (strncmp(feedback, "BAD,", 4) == 0) {
                    rejected++;
                    log_share(id, "reject", accepted, rejected, hashrate, total_hashrate,
                              elapsed_ms/1000.0, job.diff, ping, feedback+4);
                } else if (strcmp(feedback, "BLOCK") == 0) {
                    accepted++;
                    log_share(id, "block", accepted, rejected, hashrate, total_hashrate,
                              elapsed_ms/1000.0, job.diff, ping, NULL);
                } else {
                    log_info("|net0|", "%s", feedback);
                }
            }
        }
        close(sock);
        if (g_running) {
            log_warning("|net0|", "Disconnected, reconnecting in 2s...");
            sleep(2);
        }
    }
    return NULL;
}

// ==================== EXPORT FUNCTIONS ====================

void start_mining(const char *username,
                  const char *key,
                  const char *diff,
                  const char *rig,
                  int threads,
                  int nice,
                  const char *pool_ip,
                  int pool_port,
                  int intensity,
                  const char *pool_name) {
    if (g_running) return;
    
    strncpy(g_config.username, username, 63);
    strncpy(g_config.mining_key, key, 63);
    strncpy(g_config.difficulty, diff, 15);
    strncpy(g_config.rig_identifier, rig, 63);
    strncpy(g_config.pool_ip, pool_ip, 63);
    g_config.thread_count = (threads < 1) ? 1 : threads;
    g_config.nice_level = nice;
    g_config.pool_port = pool_port;
    g_config.intensity = intensity;
    g_config.single_id = rand() % 2812;
    
    strncpy(g_pool_info.name, pool_name, 63);
    strncpy(g_pool_info.ip, pool_ip, 63);
    g_pool_info.port = pool_port;
    
    const char *diff_display = "MEDIUM";
    if (strcmp(diff, "LOW") == 0) diff_display = "LOW";
    else if (strcmp(diff, "NET") == 0) diff_display = "NET";
    log_startup_info(username, diff_display, rig);
    
    g_running = 1;
    setpriority(PRIO_PROCESS, 0, nice);
    
    g_thread_count = g_config.thread_count;
    g_threads = (pthread_t*)malloc(g_thread_count * sizeof(pthread_t));
    int *ids = (int*)malloc(g_thread_count * sizeof(int));
    
    memset(g_hashrates, 0, sizeof(g_hashrates));
    
    for (int i=0; i<g_thread_count; i++) {
        ids[i] = i;
        pthread_create(&g_threads[i], NULL, worker_thread, &ids[i]);
        usleep(100000);
    }
    add_log("✅ Miner started!");
}

void stop_mining() {
    if (!g_running) return;
    g_running = 0;
    for (int i=0; i<g_thread_count; i++) {
        pthread_join(g_threads[i], NULL);
    }
    free(g_threads);
    g_threads = NULL;
    g_thread_count = 0;
    add_log("🛑 Miner stopped.");
}

int is_mining_running() {
    return g_running;
}