#!/usr/bin/env python3
"""
recortar.py - Recorta una captura de evidencia a la region util.

Las capturas de pantalla completa incluyen la barra de tareas, ventanas de
fondo y espacio vacio. Este script recorta a un rectangulo explicito, o
detecta automaticamente el area con contenido cuando el fondo es uniforme.

Uso:
    python3 scripts/recortar.py <archivo> --caja IZQ ARRIBA DER ABAJO
    python3 scripts/recortar.py <archivo> --auto [--margen 12]
"""

import argparse
import pathlib
import sys

from PIL import Image


def caja_automatica(im, margen):
    """Devuelve el rectangulo que contiene todo lo distinto del fondo.

    Se toma como color de fondo el del pixel de la esquina inferior derecha,
    que en una ventana de terminal maximizada es siempre area vacia.
    """
    rgb = im.convert("RGB")
    fondo = rgb.getpixel((rgb.width - 1, rgb.height - 1))

    # Imagen de diferencia contra el fondo: getbbox() ignora los ceros.
    from PIL import ImageChops
    diferencia = ImageChops.difference(rgb, Image.new("RGB", rgb.size, fondo))
    caja = diferencia.getbbox()
    if caja is None:
        return None

    izq, arriba, der, abajo = caja
    return (
        max(0, izq - margen),
        max(0, arriba - margen),
        min(rgb.width, der + margen),
        min(rgb.height, abajo + margen),
    )


def main():
    p = argparse.ArgumentParser()
    p.add_argument("archivo")
    p.add_argument("--caja", nargs=4, type=int,
                   metavar=("IZQ", "ARRIBA", "DER", "ABAJO"))
    p.add_argument("--auto", action="store_true")
    p.add_argument("--margen", type=int, default=12)
    args = p.parse_args()

    ruta = pathlib.Path(args.archivo)
    if not ruta.exists():
        sys.exit(f"no existe: {ruta}")

    im = Image.open(ruta)
    original = im.size

    if args.caja:
        caja = tuple(args.caja)
    elif args.auto:
        caja = caja_automatica(im, args.margen)
        if caja is None:
            sys.exit("la imagen es de un solo color: nada que recortar")
    else:
        sys.exit("indica --caja o --auto")

    recortada = im.crop(caja)
    recortada.save(ruta, "PNG", optimize=True)
    kb = ruta.stat().st_size / 1024
    print(f"  {ruta.name}: {original[0]}x{original[1]} -> "
          f"{recortada.width}x{recortada.height}  ({kb:.0f} KB)")


if __name__ == "__main__":
    main()
