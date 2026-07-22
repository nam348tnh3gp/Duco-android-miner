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

#include "DSHA1.h"

// ==================== LOG RING BUFFER ====================
#define MAX_LOG_LINES 200
#define MAX_LOG_LEN  256

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
typedef struct {
    char username[64];
    char mining_key[64];
    char difficulty[16];
    char rig_identifier[64];
    int thread_count;
    int nice_level;
    char pool_ip[64];
    int pool_port;
} Config;

static Config g_config;
static volatile int g_running = 0;
static pthread_t *g_threads = NULL;
static int g_thread_count = 0;

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

static inline long long solve_job(const Job *job, double *elapsed_ms) {
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    char nonce_str[16];
    unsigned char hash[20];
    long long max_nonce = job->diff * 100;
    char buffer[512];
    int base_len = strlen(job->base);
    memcpy(buffer, job->base, base_len);
    const unsigned char *target = job->target;
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
        if (memcmp(hash, target, 20) == 0) {
            clock_gettime(CLOCK_MONOTONIC, &end);
            *elapsed_ms = (end.tv_sec - start.tv_sec) * 1000.0 +
                          (end.tv_nsec - start.tv_nsec) / 1e6;
            return nonce;
        }
    }
    return -1;
}

static inline const char* format_hashrate(double h) {
    static char buf[64];
    if (h >= 1e9) snprintf(buf, sizeof(buf), "%.2f GH/s", h/1e9);
    else if (h >= 1e6) snprintf(buf, sizeof(buf), "%.2f MH/s", h/1e6);
    else if (h >= 1e3) snprintf(buf, sizeof(buf), "%.2f kH/s", h/1e3);
    else snprintf(buf, sizeof(buf), "%.2f H/s", h);
    return buf;
}

// ==================== WORKER THREAD ====================
void *worker_thread(void *arg) {
    int id = *(int*)arg;
    char msg[128];

    while (g_running) {
        snprintf(msg, sizeof(msg), "[T%d] 🔌 Connecting to %s:%d...", id, g_config.pool_ip, g_config.pool_port);
        add_log(msg);

        int sock = tcp_connect(g_config.pool_ip, g_config.pool_port);
        if (sock < 0) {
            snprintf(msg, sizeof(msg), "[T%d] ❌ Connection failed, retry in 5s", id);
            add_log(msg);
            sleep(5);
            continue;
        }

        char server_version[128];
        if (recv_line(sock, server_version, sizeof(server_version))) {
            snprintf(msg, sizeof(msg), "[T%d] ✅ Connected (server v%s)", id, server_version);
            add_log(msg);
        }

        int accepted = 0, rejected = 0;
        time_t t0 = time(NULL);

        while (g_running) {
            char req[256];
            snprintf(req, sizeof(req), "JOB,%s,%s,%s,\n",
                     g_config.username, g_config.difficulty, g_config.mining_key);
            if (!send_tcp(sock, req)) {
                add_log("[T] ⚠️ Send request failed");
                break;
            }

            char jobline[1024];
            if (!recv_line(sock, jobline, sizeof(jobline))) {
                add_log("[T] ⚠️ No job received");
                break;
            }

            char *base = strtok(jobline, ",");
            char *target_hex = strtok(NULL, ",");
            char *diff_str = strtok(NULL, ",");
            if (!base || !target_hex || !diff_str) {
                snprintf(msg, sizeof(msg), "[T] ⚠️ Bad job: %s", jobline);
                add_log(msg);
                continue;
            }

            Job job;
            strncpy(job.base, base, sizeof(job.base)-1);
            job.base[sizeof(job.base)-1] = '\0';
            if (strlen(target_hex) != 40) continue;
            for (int i=0; i<20; i++) sscanf(target_hex + i*2, "%2hhx", &job.target[i]);
            job.diff = atoi(diff_str);

            double elapsed_ms;
            long long nonce = solve_job(&job, &elapsed_ms);
            if (nonce >= 0) {
                double hashrate = (nonce * 1000.0) / elapsed_ms;
                char result[256];
                snprintf(result, sizeof(result), "%lld,%.2f,FlutterMiner,%s,,%d\n",
                         nonce, hashrate, g_config.rig_identifier, (int)(time(NULL)%10000));

                if (!send_tcp(sock, result)) {
                    add_log("[T] ⚠️ Send result failed");
                    break;
                }

                char feedback[128];
                if (!recv_line(sock, feedback, sizeof(feedback))) {
                    add_log("[T] ⚠️ No feedback");
                    break;
                }

                if (strcmp(feedback, "GOOD") == 0) {
                    accepted++;
                    snprintf(msg, sizeof(msg), "[T%d] ✅ Share accepted | %s | Total: %d",
                             id, format_hashrate(hashrate), accepted);
                    add_log(msg);
                } else if (strncmp(feedback, "BAD,", 4) == 0) {
                    rejected++;
                    snprintf(msg, sizeof(msg), "[T%d] ❌ Rejected: %s (rej=%d)",
                             id, feedback+4, rejected);
                    add_log(msg);
                } else if (strcmp(feedback, "BLOCK") == 0) {
                    add_log("⛓️ NEW BLOCK FOUND!");
                } else {
                    snprintf(msg, sizeof(msg), "[T] ℹ️ %s", feedback);
                    add_log(msg);
                }
            }
        }
        close(sock);
        if (g_running) {
            add_log("[T] ⚠️ Disconnected, reconnecting in 2s...");
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
                  int pool_port) {
    if (g_running) return;

    strncpy(g_config.username, username, 63);
    strncpy(g_config.mining_key, key, 63);
    strncpy(g_config.difficulty, diff, 15);
    strncpy(g_config.rig_identifier, rig, 63);
    strncpy(g_config.pool_ip, pool_ip, 63);
    g_config.thread_count = (threads < 1) ? 1 : threads;
    g_config.nice_level = nice;
    g_config.pool_port = pool_port;

    g_running = 1;
    setpriority(PRIO_PROCESS, 0, nice);

    g_thread_count = g_config.thread_count;
    g_threads = (pthread_t*)malloc(g_thread_count * sizeof(pthread_t));
    int *ids = (int*)malloc(g_thread_count * sizeof(int));

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
