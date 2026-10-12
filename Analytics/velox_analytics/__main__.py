"""Запуск як модуля: python -m velox_analytics [каталог] [--show] [--config шлях]."""

import os

from .cli import main

# Каталог над пакетом (Analytics): там шукаються CSV і VeloxConfig.swift, як для analyzer.py
main(script_dir=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
