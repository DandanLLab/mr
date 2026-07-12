#!/usr/bin/env python3
"""
生成 GBK ↔ Unicode 双向映射表 C 头文件

用法: python tools/gen_gbk_table.py
输出: quickjs/gbk_table.h

利用 Python 内置的 gbk codec，枚举所有有效 GBK 双字节编码，
生成排序数组，C 侧用二分查找 O(log N) 完成双向转换。
"""

import struct
import os

OUTPUT_PATH = os.path.join(os.path.dirname(os.path.dirname(__file__)),
                           'quickjs', 'gbk_table.h')

GBK_LEAD_MIN = 0x81
GBK_LEAD_MAX = 0xFE
GBK_TRAIL_MIN = 0x40
GBK_TRAIL_MAX = 0xFE


def generate() -> None:
    print('生成 GBK ↔ Unicode 映射表...')

    # gbk_to_unicode: dict[gbk_code, unicode]
    gbk_to_unicode = {}

    # 1. ASCII 及单字节区域（0x00-0x7F）不需要映射表
    # 2. 遍历所有双字节 GBK 编码
    for lead in range(GBK_LEAD_MIN, GBK_LEAD_MAX + 1):
        for trail in range(GBK_TRAIL_MIN, GBK_TRAIL_MAX + 1):
            if trail == 0x7F:
                continue  # 0x7F 总是无效
            gbk_bytes = bytes([lead, trail])
            try:
                # GBK 解码 → Unicode
                decoded = gbk_bytes.decode('gbk')
                if len(decoded) == 1:
                    cp = ord(decoded)
                    gbk_code = (lead << 8) | trail
                    gbk_to_unicode[gbk_code] = cp
            except UnicodeDecodeError:
                pass  # 无效编码，跳过

        if (lead - GBK_LEAD_MIN) % 0x10 == 0:
            print(f'  扫描中... {lead:#04x}xx 行 ({len(gbk_to_unicode)} 条目)')

    print(f'  总有效 GBK 编码: {len(gbk_to_unicode)}')

    if not gbk_to_unicode:
        print('错误：未能生成任何映射条目')
        return

    # 生成排序数组
    # (gbk_code, unicode) 按 gbk_code 排序
    gbk_list = sorted(gbk_to_unicode.items())
    # (unicode, gbk_code) 按 unicode 排序
    unicode_list = sorted((cp, gbk) for gbk, cp in gbk_to_unicode.items())

    write_header(gbk_list, unicode_list)
    print(f'完成！生成 {len(gbk_list)} 个映射条目 → {OUTPUT_PATH}')


def write_header(gbk_list, unicode_list) -> None:
    lines = []

    lines.append('''#ifndef GBK_TABLE_H
#define GBK_TABLE_H

#include <stdint.h>
#include <stddef.h>

/**
 * GBK ↔ Unicode 双向映射表
 *
 * 自动生成，请勿手动修改。
 * 生成源：tools/gen_gbk_table.py
 *
 * 映射表原理：
 * - gbk_to_unicode_table[]：按 GBK 编码排序，每个条目 (gbk_code, unicode)
 * - unicode_to_gbk_table[]：按 Unicode 编码排序，每个条目 (unicode, gbk_code)
 * - C 侧使用二分查找实现 O(log N) 双向转换
 *
 * 覆盖范围：GBK 编码全部有效双字节区域（0x8140-0xFEFE，不含 0x7F）
 * 包含 GBK/1、GBK/2、GBK/3、GBK/4、GBK/5 全部区域。
 */

#ifdef __cplusplus
extern "C" {
#endif

''')

    # GBK→Unicode 表
    lines.append(f'/// GBK→Unicode 映射条目数')
    lines.append(f'#define GBK_TABLE_SIZE {len(gbk_list)}')
    lines.append('')
    lines.append(f'/// GBK→Unicode 映射对 (gbk_code, unicode)')
    lines.append(f'/// 按 gbk_code 升序排列')
    lines.append(f'static const uint16_t gbk_to_unicode_table[{len(gbk_list)}][2] = {{')
    for gbk, uni in gbk_list:
        lines.append(f'    {{0x{gbk:04X}, 0x{uni:04X}}},')
    lines.append('};')
    lines.append('')

    # Unicode→GBK 表
    lines.append(f'/// Unicode→GBK 映射对 (unicode, gbk_code)')
    lines.append(f'/// 按 unicode 升序排列')
    lines.append(f'static const uint16_t unicode_to_gbk_table[{len(unicode_list)}][2] = {{')
    for uni, gbk in unicode_list:
        lines.append(f'    {{0x{uni:04X}, 0x{gbk:04X}}},')
    lines.append('};')
    lines.append('')

    lines.append('''
#ifdef __cplusplus
}
#endif

#endif /* GBK_TABLE_H */
''')

    os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)
    with open(OUTPUT_PATH, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))

    print(f'  写入 {len(gbk_list)} 条 GBK→Unicode 映射')
    print(f'  写入 {len(unicode_list)} 条 Unicode→GBK 映射')


if __name__ == '__main__':
    generate()