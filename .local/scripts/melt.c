#if 0
cc -o /tmp/melt "$0" -lsodium && /tmp/melt "$@"; exit
#endif

#include <sodium.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static const char *BIP39_URL = "https://raw.githubusercontent.com/bitcoin/bips/master/bip-0039/english.txt";

static const unsigned char b64_table[256] = {
    ['A']=0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,
    ['a']=26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,
    ['0']=52,53,54,55,56,57,58,59,60,61,['+']= 62,['/']=63
};
static const char b64_enc[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

int b64_decode(const char *in, unsigned char *out, int len) {
    int i, j = 0;
    for (i = 0; i < len; i += 4) {
        unsigned int v = (b64_table[(int)in[i]] << 18) | (b64_table[(int)in[i+1]] << 12) |
                         (b64_table[(int)in[i+2]] << 6) | b64_table[(int)in[i+3]];
        out[j++] = (v >> 16) & 0xff;
        if (in[i+2] != '=') out[j++] = (v >> 8) & 0xff;
        if (in[i+3] != '=') out[j++] = v & 0xff;
    }
    return j;
}

int b64_encode(const unsigned char *in, int len, char *out) {
    int i, j = 0;
    for (i = 0; i < len; i += 3) {
        unsigned int v = in[i] << 16;
        if (i + 1 < len) v |= in[i+1] << 8;
        if (i + 2 < len) v |= in[i+2];
        out[j++] = b64_enc[(v >> 18) & 0x3f];
        out[j++] = b64_enc[(v >> 12) & 0x3f];
        out[j++] = (i + 1 < len) ? b64_enc[(v >> 6) & 0x3f] : '=';
        out[j++] = (i + 2 < len) ? b64_enc[v & 0x3f] : '=';
    }
    out[j] = 0;
    return j;
}

int extract_seed(const char *path, unsigned char seed[32]) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;

    char line[256], b64[4096] = {0};
    while (fgets(line, sizeof(line), f)) {
        if (line[0] != '-') {
            line[strcspn(line, "\r\n")] = 0;
            strcat(b64, line);
        }
    }
    fclose(f);

    unsigned char raw[512];
    int len = b64_decode(b64, raw, strlen(b64));

    for (int i = 0; i < len - 67; i++) {
        if (raw[i] == 0 && raw[i+1] == 0 && raw[i+2] == 0 && raw[i+3] == 0x40) {
            memcpy(seed, raw + i + 4, 32);
            return 0;
        }
    }
    return -1;
}

char **load_wordlist(void) {
    static char *words[2048];
    static char buf[32768];

    char cmd[256];
    snprintf(cmd, sizeof(cmd), "curl -s '%s'", BIP39_URL);
    FILE *p = popen(cmd, "r");
    if (!p) return NULL;

    char *ptr = buf;
    for (int i = 0; i < 2048 && fgets(ptr, 32, p); i++) {
        ptr[strcspn(ptr, "\r\n")] = 0;
        words[i] = ptr;
        ptr += strlen(ptr) + 1;
    }
    pclose(p);
    return words;
}

int find_word(char **words, const char *word) {
    for (int i = 0; i < 2048; i++)
        if (strcmp(words[i], word) == 0) return i;
    return -1;
}

void write_u32(unsigned char *p, unsigned int v) {
    p[0] = (v >> 24) & 0xff; p[1] = (v >> 16) & 0xff;
    p[2] = (v >> 8) & 0xff; p[3] = v & 0xff;
}

int do_restore(const char *outpath, const char *mnemonic) {
    if (sodium_init() < 0) return 1;

    char **words = load_wordlist();
    if (!words) { fprintf(stderr, "failed to load wordlist\n"); return 1; }

    /* Parse mnemonic into indices */
    unsigned int indices[24];
    char buf[512];
    strncpy(buf, mnemonic, sizeof(buf) - 1);
    char *tok = strtok(buf, " \t\n");
    for (int i = 0; i < 24 && tok; i++, tok = strtok(NULL, " \t\n")) {
        indices[i] = find_word(words, tok);
        if (indices[i] < 0) { fprintf(stderr, "unknown word: %s\n", tok); return 1; }
    }

    /* Convert 24 x 11-bit indices to 33 bytes */
    unsigned char data[33] = {0};
    for (int i = 0; i < 24; i++) {
        int bit_offset = i * 11;
        int byte_idx = bit_offset / 8;
        int bit_idx = bit_offset % 8;
        unsigned int shifted = indices[i] << (24 - 11 - bit_idx);
        data[byte_idx] |= (shifted >> 16) & 0xff;
        data[byte_idx + 1] |= (shifted >> 8) & 0xff;
        data[byte_idx + 2] |= shifted & 0xff;
    }

    unsigned char seed[32], hash[32];
    memcpy(seed, data, 32);

    /* Verify checksum */
    crypto_hash_sha256(hash, seed, 32);
    if (hash[0] != data[32]) { fprintf(stderr, "checksum mismatch\n"); return 1; }

    /* Generate keypair */
    unsigned char pk[32], sk[64];
    crypto_sign_seed_keypair(pk, sk, seed);

    /* Build OpenSSH private key format */
    unsigned char blob[256];
    int pos = 0;

    memcpy(blob + pos, "openssh-key-v1\0", 15); pos += 15;
    write_u32(blob + pos, 4); pos += 4; memcpy(blob + pos, "none", 4); pos += 4;
    write_u32(blob + pos, 4); pos += 4; memcpy(blob + pos, "none", 4); pos += 4;
    write_u32(blob + pos, 0); pos += 4;
    write_u32(blob + pos, 1); pos += 4;

    /* Public key blob */
    write_u32(blob + pos, 51); pos += 4;
    write_u32(blob + pos, 11); pos += 4; memcpy(blob + pos, "ssh-ed25519", 11); pos += 11;
    write_u32(blob + pos, 32); pos += 4; memcpy(blob + pos, pk, 32); pos += 32;

    /* Private section */
    unsigned char priv[136];
    int ppos = 0;
    unsigned int checkint = randombytes_random();
    write_u32(priv + ppos, checkint); ppos += 4;
    write_u32(priv + ppos, checkint); ppos += 4;
    write_u32(priv + ppos, 11); ppos += 4; memcpy(priv + ppos, "ssh-ed25519", 11); ppos += 11;
    write_u32(priv + ppos, 32); ppos += 4; memcpy(priv + ppos, pk, 32); ppos += 32;
    write_u32(priv + ppos, 64); ppos += 4; memcpy(priv + ppos, sk, 64); ppos += 64;
    write_u32(priv + ppos, 0); ppos += 4; /* empty comment */
    while (ppos % 8) priv[ppos++] = ppos - 112; /* padding */

    write_u32(blob + pos, ppos); pos += 4;
    memcpy(blob + pos, priv, ppos); pos += ppos;

    /* Output */
    char b64out[512];
    b64_encode(blob, pos, b64out);

    FILE *f = fopen(outpath, "w");
    if (!f) { fprintf(stderr, "can't write to %s\n", outpath); return 1; }
    fprintf(f, "-----BEGIN OPENSSH PRIVATE KEY-----\n");
    for (int i = 0; b64out[i]; i += 70) fprintf(f, "%.70s\n", b64out + i);
    fprintf(f, "-----END OPENSSH PRIVATE KEY-----\n");
    fclose(f);
    chmod(outpath, 0600);

    /* Also output public key */
    char pubpath[512], pubb64[128];
    snprintf(pubpath, sizeof(pubpath), "%s.pub", outpath);
    unsigned char pubbuf[51];
    write_u32(pubbuf, 11); memcpy(pubbuf + 4, "ssh-ed25519", 11);
    write_u32(pubbuf + 15, 32); memcpy(pubbuf + 19, pk, 32);
    b64_encode(pubbuf, 51, pubb64);
    f = fopen(pubpath, "w");
    fprintf(f, "ssh-ed25519 %s\n", pubb64);
    fclose(f);

    printf("wrote %s and %s\n", outpath, pubpath);
    return 0;
}

int do_encode(const char *keyfile) {
    if (sodium_init() < 0) { fprintf(stderr, "sodium init failed\n"); return 1; }

    unsigned char seed[32], hash[32], data[33];
    if (extract_seed(keyfile, seed) < 0) { fprintf(stderr, "failed to read key: %s\n", keyfile); return 1; }

    crypto_hash_sha256(hash, seed, 32);
    memcpy(data, seed, 32);
    data[32] = hash[0];

    char **words = load_wordlist();
    if (!words) { fprintf(stderr, "failed to load wordlist\n"); return 1; }

    for (int i = 0; i < 24; i++) {
        int bit_offset = i * 11;
        int byte_idx = bit_offset / 8;
        int bit_idx = bit_offset % 8;
        unsigned int idx = (data[byte_idx] << 16) | (data[byte_idx+1] << 8) | data[byte_idx+2];
        idx = (idx >> (24 - 11 - bit_idx)) & 0x7ff;
        printf("%s%s", words[idx], i < 23 ? " " : "\n");
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "restore") == 0) {
        if (argc < 4) {
            fprintf(stderr, "usage: melt restore <outfile> <mnemonic...>\n");
            return 1;
        }
        char mnemonic[512] = {0};
        for (int i = 3; i < argc; i++) {
            if (i > 3) strcat(mnemonic, " ");
            strcat(mnemonic, argv[i]);
        }
        return do_restore(argv[2], mnemonic);
    }

    char default_path[256];
    const char *keyfile;
    if (argc <= 1 && getenv("HOME")) {
        snprintf(default_path, sizeof(default_path), "%s/.ssh/id_ed25519", getenv("HOME"));
        keyfile = default_path;
    } else {
        keyfile = argv[1];
    }
    return do_encode(keyfile);
}
