"""Genera ejemplos/documento_ejemplo.png: un documento ficticio para probar el OCR de la IA.
Uso: python3 scripts/generar_ejemplo.py   (requiere Pillow: pip install pillow)"""
import os
from PIL import Image, ImageDraw, ImageFont

def fuente(tam, negrita=False):
    try:
        return ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans%s.ttf" % ("-Bold" if negrita else ""), tam)
    except OSError:
        return ImageFont.load_default()

W, H = 900, 560
im = Image.new("L", (W, H), 255)
d = ImageDraw.Draw(im)
d.rectangle([10, 10, W - 10, H - 10], outline=0, width=3)
d.text((40, 35), "DOCUMENTO DE EJEMPLO — SIN VALIDEZ LEGAL", font=fuente(22, True), fill=0)
d.text((40, 75), "Notificación de resolución migratoria (caso ficticio de prueba)", font=fuente(20), fill=0)
y = 130
for k, v in [("Nombre", "María Fernanda Rojas Quispe"), ("Nacionalidad", "Peruana"),
             ("Documento", "Pasaporte N° ZX0000000 (ficticio)"), ("Materia", "Orden de abandono del país"),
             ("Plazo para descargos", "5 días hábiles desde la notificación"),
             ("Fecha de notificación", "20-11-2026"), ("Vencimiento del plazo", "27-11-2026")]:
    d.text((40, y), k + ":", font=fuente(19, True), fill=0)
    d.text((330, y), v, font=fuente(19), fill=0)
    y += 42
d.text((40, y + 20), "La persona puede presentar antecedentes ante la autoridad migratoria", font=fuente(18), fill=0)
d.text((40, y + 48), "dentro del plazo indicado. Este archivo se usa solo para probar el OCR.", font=fuente(18), fill=0)
os.makedirs("ejemplos", exist_ok=True)
im.save("ejemplos/documento_ejemplo.png", optimize=True)
print("ejemplos/documento_ejemplo.png")
