# -*- coding: utf-8 -*-
"""
FPGA BMP图片转换工具
===================
功能：将任意格式图片转换为640x480、24位无压缩BMP格式，适配HX4S20 FPGA工程。

使用方法：
    python convert_images.py                    # 批量转换 input_images/ 目录下的图片
    python convert_images.py input.jpg output.bmp  # 转换单张图片

说明：
    - 输出BMP为标准格式（bottom-up, 24-bit, 无压缩）
    - FPGA工程的 frame_fifo_read 已配置行倒序读取(ROW_REVERSE=1)，无需额外翻转
    - 如果使用未修改的原始工程，需加 --rotate180 参数预翻转图片
"""

import os
import sys
import argparse
from PIL import Image


def convert_single_file(input_path, output_path, target_width=640, target_height=480, rotate180=False):
    """将单张图片转换为指定分辨率的无压缩24-bit BMP格式。"""
    if not os.path.exists(input_path):
        print(f"[错误] 找不到输入文件: {input_path}")
        return False

    try:
        with Image.open(input_path) as img:
            img_rgb = img.convert('RGB')
            img_resized = img_rgb.resize((target_width, target_height), Image.Resampling.LANCZOS)

            if rotate180:
                img_resized = img_resized.rotate(180)

            if not output_path.lower().endswith('.bmp'):
                output_path += '.bmp'

            img_resized.save(output_path, 'BMP')
            print(f"[成功] {input_path} -> {output_path}")
            return True
    except Exception as e:
        print(f"[失败] 转换 {input_path} 时发生错误: {e}")
        return False


def convert_batch(input_dir, output_dir, target_width=640, target_height=480, rotate180=False):
    """批量将图片转换为指定分辨率的无压缩24-bit BMP格式。"""
    if not os.path.exists(output_dir):
        os.makedirs(output_dir)

    supported_formats = ('.png', '.jpg', '.jpeg', '.bmp', '.webp', '.gif', '.tiff')
    files = [f for f in os.listdir(input_dir) if f.lower().endswith(supported_formats)]

    if not files:
        print(f"在目录 '{input_dir}' 中没有找到支持的图片文件。")
        return

    print(f"找到 {len(files)} 个图片文件，开始转换...")
    success_count = 0

    for filename in files:
        input_path = os.path.join(input_dir, filename)
        base_name = os.path.splitext(filename)[0]
        output_filename = f"{base_name}_640x480.bmp"
        output_path = os.path.join(output_dir, output_filename)

        if convert_single_file(input_path, output_path, target_width, target_height, rotate180):
            success_count += 1

    print(f"\n转换完成！共成功转换 {success_count} 个文件。")
    print(f"请将 '{output_dir}' 目录下的所有 BMP 文件复制到 TF(SD) 卡的根目录中。")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="FPGA TF卡 BMP 图片转换工具 (640x480, 24位无压缩)")
    parser.add_argument('input', nargs='?', help='输入图片文件路径')
    parser.add_argument('output', nargs='?', help='输出BMP文件路径')
    parser.add_argument('--rotate180', action='store_true',
                        help='旋转180度（用于未修改的原始工程）')

    args = parser.parse_args()

    if args.input and args.output:
        convert_single_file(args.input, args.output, rotate180=args.rotate180)
    else:
        current_dir = os.path.dirname(os.path.abspath(__file__))
        default_input = os.path.join(current_dir, "input_images")
        default_output = os.path.join(current_dir, "output_bmp")

        print("=== FPGA TF卡 BMP 图片转换工具 ===")
        print("要求：640x480, 24位无压缩 BMP")
        print("-" * 40)

        if args.rotate180:
            print("[模式] 旋转180度（兼容原始工程）")
        else:
            print("[模式] 正常方向（配合修改后的工程 ROW_REVERSE=1）")

        print("-" * 40)

        if not os.path.exists(default_input):
            os.makedirs(default_input)
            print(f"已创建默认输入目录: {default_input}")
            print(f"请将需要转换的图片放入该目录，然后重新运行本脚本。")
            sys.exit(0)

        convert_batch(default_input, default_output, rotate180=args.rotate180)
