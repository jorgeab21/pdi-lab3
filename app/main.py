"""PDI · Canal digital de trámites migratorios — Prueba de concepto (Lab 3, TICS413).

Una sola aplicación FastAPI que corre en Cloud Run y cumple los dos roles del diseño:
  - pdi-web-portal: formulario del ciudadano, página de seguimiento y bandeja de detectives.
  - pdi-backend-api: recibe el trámite, guarda el adjunto, lo encola en Pub/Sub,
    lo clasifica con IA (Gemini de Vertex AI o M icrosoft Foundry) de Microsoft Foundry (Azure) y lo registra en Cloud SQL.

Sin variables de entorno funciona en modo local (SQLite, carpeta local y clasificación simulada),
para poder probarla en un computador antes de desplegar.
"""
import base64
import json
import logging
import os
import time
import re
import secrets
import uuid
from datetime import datetime, timezone

from fastapi import BackgroundTasks, Depends, FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from fastapi.templating import Jinja2Templates
from sqlalchemy import Column, DateTime, Integer, String, Text, create_engine, select
from sqlalchemy.orm import Session, declarative_base, sessionmaker

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("pdi")

# ---------------------------------------------------------------- configuración
DATABASE_URL = os.getenv("DATABASE_URL", "sqlite:///./local.db")
if os.getenv("DB_SOCKET") and os.getenv("DB_PASSWORD"):   # Cloud SQL vía el conector de Cloud Run
    from urllib.parse import quote
    DATABASE_URL = (f"postgresql+pg8000://pdi:{quote(os.environ['DB_PASSWORD'])}@/tramites"
                    f"?unix_sock={os.environ['DB_SOCKET']}")
BUCKET = os.getenv("BUCKET", "")                       # vacío = carpeta local ./adjuntos
PROJECT = os.getenv("GOOGLE_CLOUD_PROJECT", "")
TOPIC_INGESTA = os.getenv("TOPIC_INGESTA", "")         # vacío = se procesa en la misma petición
TOPIC_PREFIJO = os.getenv("TOPIC_PRIORIDAD_PREFIJO", "tramites-prioridad-")
AZURE_ENDPOINT = os.getenv("AZURE_OPENAI_ENDPOINT", "")
AZURE_KEY = os.getenv("AZURE_OPENAI_KEY", "")
AZURE_DEPLOYMENT = os.getenv("AZURE_OPENAI_DEPLOYMENT", "")
AZURE_API_VERSION = os.getenv("AZURE_OPENAI_API_VERSION", "2024-10-21")
VERTEX_MODEL = os.getenv("VERTEX_MODEL", "")           # ej. gemini-3.8-flash (vacío = no se usa Vertex)
VERTEX_LOCATION = os.getenv("VERTEX_LOCATION", "global")
BANDEJA_USUARIO = os.getenv("BANDEJA_USUARIO", "detective")
BANDEJA_CLAVE = os.getenv("BANDEJA_CLAVE", "pdi-demo")
PUBSUB_TOKEN = os.getenv("PUBSUB_TOKEN", "")           # token simple que valida los avisos de Pub/Sub

ORDEN_PRIORIDAD = {"Alta": 0, "Media": 1, "Baja": 2}

# ---------------------------------------------------------------- base de datos
engine = create_engine(DATABASE_URL, pool_pre_ping=True,
                       connect_args={"check_same_thread": False} if DATABASE_URL.startswith("sqlite") else {})
SessionLocal = sessionmaker(bind=engine)
Base = declarative_base()


class Tramite(Base):
    __tablename__ = "tramites"
    id = Column(Integer, primary_key=True, autoincrement=True)
    numero = Column(String(32), unique=True)
    codigo = Column(String(32), unique=True, index=True)      # código aleatorio del enlace de seguimiento
    nombre = Column(String(200))
    correo = Column(String(200))
    asunto = Column(String(300))
    mensaje = Column(Text)
    adjunto = Column(String(500))                            # ruta en Cloud Storage (o local)
    adjunto_tipo = Column(String(100))
    estado = Column(String(30), default="Recibido")          # Recibido → Clasificado → En revisión → Resuelto
    prioridad = Column(String(10))
    categoria = Column(String(100))
    tipo_documento = Column(String(100))
    resumen = Column(Text)
    texto_ocr = Column(Text)
    motor_ia = Column(String(100))
    creado = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))
    actualizado = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))


Base.metadata.create_all(engine)


def db():
    s = SessionLocal()
    try:
        yield s
    finally:
        s.close()


# ---------------------------------------------------------------- almacenamiento de adjuntos
def guardar_adjunto(nombre: str, datos: bytes, tipo: str) -> str:
    if BUCKET:
        from google.cloud import storage
        blob = storage.Client().bucket(BUCKET).blob(nombre)
        blob.upload_from_string(datos, content_type=tipo)
        return f"gs://{BUCKET}/{nombre}"
    os.makedirs("adjuntos", exist_ok=True)
    ruta = os.path.join("adjuntos", nombre.replace("/", "_"))
    with open(ruta, "wb") as f:
        f.write(datos)
    return ruta


def leer_adjunto(ruta: str) -> bytes:
    if ruta.startswith("gs://"):
        from google.cloud import storage
        bucket, nombre = ruta[5:].split("/", 1)
        return storage.Client().bucket(bucket).blob(nombre).download_as_bytes()
    with open(ruta, "rb") as f:
        return f.read()


# ---------------------------------------------------------------- Pub/Sub
def publicar(topico: str, mensaje: dict):
    if not (topico and PROJECT):
        return
    from google.cloud import pubsub_v1
    pub = pubsub_v1.PublisherClient()
    pub.publish(pub.topic_path(PROJECT, topico), json.dumps(mensaje).encode()).result(timeout=30)


# ---------------------------------------------------------------- IA (Microsoft Foundry / Azure OpenAI)
PROMPT = """Eres el clasificador de trámites del Departamento de Migraciones de la PDI (Chile).
Recibes el correo de un ciudadano y, si viene, la imagen de su documento (cédula o pasaporte).
1. Lee el documento (OCR) y transcribe los datos visibles más importantes.
2. Clasifica el trámite y asigna prioridad:
   - Alta: orden de expulsión, plazo legal vencido o por vencer en menos de 7 días, menores de edad, riesgo humanitario.
   - Media: renovaciones, residencias, documentos por vencer en menos de 30 días.
   - Baja: consultas generales o información.
Responde SOLO un JSON con estas claves:
{"tipo_documento": "...", "texto_ocr": "...", "categoria": "...", "prioridad": "Alta|Media|Baja", "resumen": "máx. 2 frases"}"""


def _parsear_json(texto: str) -> dict:
    m = re.search(r"\{.*\}", texto or "", re.S)
    return json.loads(m.group(0)) if m else {}


def clasificar_simulado(asunto: str, texto: str, motivo: str = "simulado") -> dict:
    """Reglas simples por palabra clave: se usa sin credenciales de Azure o si Azure no responde."""
    t = texto.lower()
    prioridad = "Alta" if re.search(r"expuls|urgente|vence (mañana|hoy)|menor", t) else \
                "Media" if re.search(r"renov|residen|vence|venc", t) else "Baja"
    return {"tipo_documento": "No analizado (modo simulado)", "texto_ocr": "",
            "categoria": "Trámite migratorio", "prioridad": prioridad,
            "resumen": f"Clasificación simulada: {asunto[:120]}", "motor_ia": motivo}


def motor_ia() -> str:
    if AZURE_ENDPOINT and AZURE_KEY and AZURE_DEPLOYMENT:
        return "azure"
    if VERTEX_MODEL and PROJECT:
        return "vertex"
    return "simulado"


_sesion_vertex = None


def clasificar_vertex(texto: str, archivo: bytes | None, tipo: str) -> dict:
    """Gemini en Vertex AI con la cuenta de servicio de Cloud Run (sin claves): lee imágenes y PDF."""
    global _sesion_vertex
    if _sesion_vertex is None:
        import google.auth
        from google.auth.transport.requests import AuthorizedSession
        cred, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
        _sesion_vertex = AuthorizedSession(cred)
    partes = [{"text": texto}]
    if archivo and (tipo.startswith("image/") or tipo == "application/pdf"):
        partes.append({"inline_data": {"mime_type": tipo, "data": base64.b64encode(archivo).decode()}})
    host = "aiplatform.googleapis.com" if VERTEX_LOCATION == "global" else f"{VERTEX_LOCATION}-aiplatform.googleapis.com"
    url = (f"https://{host}/v1/projects/{PROJECT}/locations/{VERTEX_LOCATION}"
           f"/publishers/google/models/{VERTEX_MODEL}:generateContent")
    cuerpo = {"systemInstruction": {"parts": [{"text": PROMPT}]},
              "contents": [{"role": "user", "parts": partes}],
              "generationConfig": {"temperature": 0.2, "responseMimeType": "application/json"}}
    r = _sesion_vertex.post(url, json=cuerpo, timeout=90)
    r.raise_for_status()
    salida = "".join(p.get("text", "") for p in r.json()["candidates"][0]["content"]["parts"])
    return _parsear_json(salida)


def clasificar(asunto: str, mensaje: str, imagen: bytes | None, tipo: str) -> dict:
    texto = f"Asunto: {asunto}\nMensaje del ciudadano:\n{mensaje}"
    motor = motor_ia()
    if motor == "simulado":
        return clasificar_simulado(asunto, texto)
    if motor == "vertex":
        inicio = time.monotonic()
        try:
            datos = clasificar_vertex(texto, imagen, tipo)
        except Exception as e:  # Vertex caído o sin cuota: el trámite no se pierde
            log.error("Vertex AI no respondió, se usa el modo simulado: %s", e)
            return clasificar_simulado(asunto, texto, "simulado (Vertex no disponible)")
        if datos.get("prioridad") not in ORDEN_PRIORIDAD:
            datos["prioridad"] = "Media"
        datos["motor_ia"] = f"Gemini en Vertex AI · {VERTEX_MODEL} ({time.monotonic() - inicio:.1f} s)"
        return datos

    from openai import AzureOpenAI
    cliente = AzureOpenAI(azure_endpoint=AZURE_ENDPOINT, api_key=AZURE_KEY, api_version=AZURE_API_VERSION,
                          timeout=60, max_retries=2)
    contenido = [{"type": "text", "text": texto}]
    if imagen and tipo.startswith("image/"):
        url = f"data:{tipo};base64,{base64.b64encode(imagen).decode()}"
        contenido.append({"type": "image_url", "image_url": {"url": url}})
    try:
        r = cliente.chat.completions.create(
            model=AZURE_DEPLOYMENT,
            messages=[{"role": "system", "content": PROMPT}, {"role": "user", "content": contenido}])
    except Exception as e:  # el modelo puede no aceptar imágenes: se reintenta solo con texto
        log.warning("Reintento sin imagen: %s", e)
        try:
            r = cliente.chat.completions.create(
                model=AZURE_DEPLOYMENT,
                messages=[{"role": "system", "content": PROMPT}, {"role": "user", "content": texto}])
        except Exception as e2:  # Azure caído o sin cuota: el trámite no se pierde, queda con reglas simples
            log.error("Azure Foundry no respondió, se usa el modo simulado: %s", e2)
            return clasificar_simulado(asunto, texto, "simulado (Azure no disponible)")
    datos = _parsear_json(r.choices[0].message.content)
    if datos.get("prioridad") not in ORDEN_PRIORIDAD:
        datos["prioridad"] = "Media"
    datos["motor_ia"] = f"Azure Foundry · {AZURE_DEPLOYMENT}"
    return datos


def procesar(tramite_id: int):
    """Paso asíncrono: descarga el adjunto, lo clasifica con IA, actualiza la BD y publica por prioridad."""
    with SessionLocal() as s:
        t = s.get(Tramite, tramite_id)
        if not t or t.estado != "Recibido":
            return
        imagen = leer_adjunto(t.adjunto) if t.adjunto else None
        r = clasificar(t.asunto or "", t.mensaje or "", imagen, t.adjunto_tipo or "")
        t.prioridad = r.get("prioridad")
        t.categoria = str(r.get("categoria", ""))[:100]
        t.tipo_documento = str(r.get("tipo_documento", ""))[:100]
        t.resumen = r.get("resumen", "")
        t.texto_ocr = r.get("texto_ocr", "") if isinstance(r.get("texto_ocr"), str) else json.dumps(r.get("texto_ocr"), ensure_ascii=False)
        t.motor_ia = r.get("motor_ia", "")
        t.estado = "Clasificado"
        t.actualizado = datetime.now(timezone.utc)
        s.commit()
        publicar(TOPIC_PREFIJO + t.prioridad.lower(), {"id": t.id, "numero": t.numero, "prioridad": t.prioridad})
        log.info("Trámite %s clasificado con prioridad %s", t.numero, t.prioridad)


# ---------------------------------------------------------------- web
app = FastAPI(title="PDI · Trámites migratorios (PoC)")
templates = Jinja2Templates(directory=os.path.join(os.path.dirname(__file__), "templates"))
seguridad = HTTPBasic()


def detective(cred: HTTPBasicCredentials = Depends(seguridad)):
    ok = secrets.compare_digest(cred.username, BANDEJA_USUARIO) and secrets.compare_digest(cred.password, BANDEJA_CLAVE)
    if not ok:
        raise HTTPException(401, "Credenciales inválidas", headers={"WWW-Authenticate": "Basic"})
    return cred.username


@app.get("/", response_class=HTMLResponse)
def inicio(request: Request):
    return templates.TemplateResponse(request, "inicio.html", {})


@app.post("/tramites", response_class=HTMLResponse)
async def crear_tramite(request: Request, tareas: BackgroundTasks,
                        nombre: str = Form(...), correo: str = Form(...), asunto: str = Form(...),
                        mensaje: str = Form(...), documento: UploadFile | None = File(None),
                        s: Session = Depends(db)):
    t = Tramite(codigo=secrets.token_urlsafe(9), nombre=nombre, correo=correo, asunto=asunto, mensaje=mensaje)
    if documento and documento.filename:
        datos = await documento.read()
        if len(datos) > 8 * 1024 * 1024:
            raise HTTPException(413, "El archivo supera 8 MB")
        tipo = documento.content_type or "application/octet-stream"
        t.adjunto = guardar_adjunto(f"tramites/{uuid.uuid4()}-{documento.filename}", datos, tipo)
        t.adjunto_tipo = tipo
    s.add(t)
    s.commit()
    t.numero = f"PDI-{datetime.now().year}-{t.id:06d}"
    s.commit()
    if TOPIC_INGESTA and PROJECT:
        publicar(TOPIC_INGESTA, {"id": t.id})          # Pub/Sub entrega el aviso a /pubsub/procesar
    else:
        tareas.add_task(procesar, t.id)                # modo local: se procesa en segundo plano
    enlace = str(request.url_for("seguimiento")) + f"?codigo={t.codigo}"
    return templates.TemplateResponse(request, "recibido.html", {"t": t, "enlace": enlace})


@app.post("/pubsub/procesar")
async def pubsub_procesar(request: Request, token: str = ""):
    if PUBSUB_TOKEN and not secrets.compare_digest(token, PUBSUB_TOKEN):
        raise HTTPException(403)
    sobre = await request.json()
    datos = json.loads(base64.b64decode(sobre["message"]["data"]))
    procesar(int(datos["id"]))
    return Response(status_code=204)


@app.get("/seguimiento", response_class=HTMLResponse, name="seguimiento")
def seguimiento(request: Request, codigo: str = "", s: Session = Depends(db)):
    t = s.scalar(select(Tramite).where(Tramite.codigo == codigo)) if codigo else None
    return templates.TemplateResponse(request, "seguimiento.html", {"t": t, "codigo": codigo},
                                      status_code=404 if codigo and not t else 200)


@app.get("/bandeja", response_class=HTMLResponse)
def bandeja(request: Request, usuario: str = Depends(detective), s: Session = Depends(db)):
    filas = s.scalars(select(Tramite)).all()
    filas.sort(key=lambda t: (ORDEN_PRIORIDAD.get(t.prioridad or "", 3), -(t.id or 0)))
    return templates.TemplateResponse(request, "bandeja.html", {"filas": filas, "usuario": usuario})


@app.get("/bandeja/{tid}", response_class=HTMLResponse)
def detalle(request: Request, tid: int, usuario: str = Depends(detective), s: Session = Depends(db)):
    t = s.get(Tramite, tid) or HTTPException(404)
    if isinstance(t, HTTPException):
        raise t
    return templates.TemplateResponse(request, "detalle.html", {"t": t})


@app.get("/bandeja/{tid}/documento")
def documento(tid: int, usuario: str = Depends(detective), s: Session = Depends(db)):
    t = s.get(Tramite, tid)
    if not t or not t.adjunto:
        raise HTTPException(404)
    return Response(leer_adjunto(t.adjunto), media_type=t.adjunto_tipo or "application/octet-stream")


@app.post("/bandeja/{tid}/estado")
def cambiar_estado(tid: int, estado: str = Form(...), usuario: str = Depends(detective), s: Session = Depends(db)):
    if estado not in ("En revisión", "Resuelto"):
        raise HTTPException(400)
    t = s.get(Tramite, tid)
    if not t:
        raise HTTPException(404)
    t.estado = estado
    t.actualizado = datetime.now(timezone.utc)
    s.commit()
    return RedirectResponse(f"/bandeja/{tid}", status_code=303)


@app.get("/salud")
def salud():
    return {"ok": True, "ia": motor_ia(), "modelo": AZURE_DEPLOYMENT if motor_ia() == "azure" else VERTEX_MODEL, "bd": DATABASE_URL.split(":")[0],
            "pubsub": bool(TOPIC_INGESTA), "bucket": bool(BUCKET)}
