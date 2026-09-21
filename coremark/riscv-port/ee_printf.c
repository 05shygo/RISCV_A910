#include "coremark.h"
#include <stdarg.h>

#define ZEROPAD   (1 << 0)
#define SIGN      (1 << 1)
#define PLUS      (1 << 2)
#define SPACE     (1 << 3)
#define LEFT      (1 << 4)
#define HEX_PREP  (1 << 5)
#define UPPERCASE (1 << 6)

#define is_digit(c) ((c) >= '0' && (c) <= '9')

static char *digits = "0123456789abcdefghijklmnopqrstuvwxyz";
static char *upper_digits = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";

// Simple putchar - writes to MONITOR peripheral for character output
static void putchar(char c) {
    // Write to MONITOR peripheral at 0x80000000
    // This matches the system's peripheral address map
    volatile unsigned int *monitor = (volatile unsigned int *)0x80000000;
    *monitor = (unsigned int)c;
}

static ee_size_t strnlen(const char *s, ee_size_t count) {
    const char *sc;
    for (sc = s; *sc != '\0' && count--; ++sc);
    return sc - s;
}

static int skip_atoi(const char **s) {
    int i = 0;
    while (is_digit(**s))
        i = i * 10 + *((*s)++) - '0';
    return i;
}

static char *number(char *str, long num, int base, int size, int precision, int type) {
    char c, sign, tmp[66];
    char *dig = digits;
    int i;

    if (type & UPPERCASE) dig = upper_digits;
    if (type & LEFT) type &= ~ZEROPAD;
    if (base < 2 || base > 36) return 0;

    c = (type & ZEROPAD) ? '0' : ' ';
    sign = 0;
    if (type & SIGN) {
        if (num < 0) {
            sign = '-';
            num = -num;
            size--;
        } else if (type & PLUS) {
            sign = '+';
            size--;
        } else if (type & SPACE) {
            sign = ' ';
            size--;
        }
    }

    if (type & HEX_PREP) {
        if (base == 16) size -= 2;
        else if (base == 8) size--;
    }

    i = 0;
    if (num == 0)
        tmp[i++] = '0';
    else {
        while (num != 0) {
            tmp[i++] = dig[((unsigned long)num) % (unsigned)base];
            num = ((unsigned long)num) / (unsigned)base;
        }
    }

    if (i > precision) precision = i;
    size -= precision;

    if (!(type & (ZEROPAD | LEFT)))
        while (size-- > 0) *str++ = ' ';
    if (sign) *str++ = sign;

    if (type & HEX_PREP) {
        if (base == 8)
            *str++ = '0';
        else if (base == 16) {
            *str++ = '0';
            *str++ = digits[33];
        }
    }

    if (!(type & LEFT))
        while (size-- > 0) *str++ = c;
    while (i < precision--) *str++ = '0';
    while (i-- > 0) *str++ = tmp[i];
    while (size-- > 0) *str++ = ' ';

    return str;
}

int ee_printf(const char *fmt, ...) {
    char printf_buf[512];
    va_list args;
    int i;
    char *str;
    char *s;
    int *ip;

    int flags;
    int field_width;
    int precision;
    int qualifier;

    str = printf_buf;
    va_start(args, fmt);

    for (; *fmt; fmt++) {
        if (*fmt != '%') {
            *str++ = *fmt;
            continue;
        }

        flags = 0;
    repeat:
        fmt++;
        switch (*fmt) {
            case '-': flags |= LEFT; goto repeat;
            case '+': flags |= PLUS; goto repeat;
            case ' ': flags |= SPACE; goto repeat;
            case '#': flags |= HEX_PREP; goto repeat;
            case '0': flags |= ZEROPAD; goto repeat;
        }

        field_width = -1;
        if (is_digit(*fmt))
            field_width = skip_atoi(&fmt);
        else if (*fmt == '*') {
            fmt++;
            field_width = va_arg(args, int);
            if (field_width < 0) {
                field_width = -field_width;
                flags |= LEFT;
            }
        }

        precision = -1;
        if (*fmt == '.') {
            ++fmt;
            if (is_digit(*fmt))
                precision = skip_atoi(&fmt);
            else if (*fmt == '*') {
                ++fmt;
                precision = va_arg(args, int);
            }
            if (precision < 0) precision = 0;
        }

        qualifier = -1;
        if (*fmt == 'h' || *fmt == 'l' || *fmt == 'L') {
            qualifier = *fmt;
            fmt++;
        }

        switch (*fmt) {
            case 'c':
                if (!(flags & LEFT))
                    while (--field_width > 0) *str++ = ' ';
                *str++ = (unsigned char)va_arg(args, int);
                while (--field_width > 0) *str++ = ' ';
                continue;

            case 's':
                s = va_arg(args, char *);
                if (!s) s = "<NULL>";
                i = strnlen(s, precision);
                if (!(flags & LEFT))
                    while (i < field_width--) *str++ = ' ';
                for (; i > 0; i--) *str++ = *s++;
                while (i < field_width--) *str++ = ' ';
                continue;

            case 'p':
                if (field_width == -1) {
                    field_width = 2 * sizeof(void *);
                    flags |= ZEROPAD;
                }
                str = number(str, (unsigned long)va_arg(args, void *), 16,
                           field_width, precision, flags);
                continue;

            case 'n':
                ip = va_arg(args, int *);
                *ip = (str - printf_buf);
                continue;

            case 'o':
                str = number(str, va_arg(args, unsigned long), 8,
                           field_width, precision, flags);
                continue;

            case 'x':
                flags |= HEX_PREP;
                str = number(str, va_arg(args, unsigned long), 16,
                           field_width, precision, flags);
                continue;

            case 'X':
                flags |= UPPERCASE | HEX_PREP;
                str = number(str, va_arg(args, unsigned long), 16,
                           field_width, precision, flags);
                continue;

            case 'd':
            case 'i':
                flags |= SIGN;
            case 'u':
                str = number(str, va_arg(args, unsigned long), 10,
                           field_width, precision, flags);
                continue;

            default:
                if (*fmt != '%') *str++ = '%';
                if (*fmt)
                    *str++ = *fmt;
                else
                    --fmt;
                continue;
        }
    }
    *str = '\0';
    va_end(args);

    // Output the buffer
    for (i = 0; printf_buf[i]; i++)
        putchar(printf_buf[i]);

    return i;
}
