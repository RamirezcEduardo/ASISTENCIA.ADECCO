"""
Prototipo de reconocimiento facial para asistencia (GUI local con OpenCV).

Pipeline 100% offline, sin dlib/tensorflow:
  - Deteccion: YuNet (cv2.FaceDetectorYN)
  - Reconocimiento: SFace (cv2.FaceRecognizerSF) -> embedding de 128 valores,
    comparado por similitud coseno.

Controles (con la ventana de video enfocada):
  E - Enrolar el rostro mas grande visible (pide DNI y nombre por consola)
  R - Activar/desactivar reconocimiento en vivo
  L - Listar colaboradores enrolados
  Q / ESC - Salir
"""
import json
import os
import time

import cv2
import numpy as np

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
MODELS_DIR = os.path.join(BASE_DIR, "models")
DETECTOR_PATH = os.path.join(MODELS_DIR, "face_detection_yunet_2023mar.onnx")
RECOGNIZER_PATH = os.path.join(MODELS_DIR, "face_recognition_sface_2021dec.onnx")
DB_PATH = os.path.join(BASE_DIR, "rostros_enrolados.json")

COSINE_THRESHOLD = 0.363  # umbral recomendado por el modelo SFace para "misma persona"
FRAME_W, FRAME_H = 640, 480
ENROLL_SAMPLES = 3


def cargar_db():
    if os.path.exists(DB_PATH):
        with open(DB_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        for r in data:
            r["embedding"] = np.array(r["embedding"], dtype=np.float32)
        return data
    return []


def guardar_db(db):
    serializable = [
        {"dni": r["dni"], "nombre": r["nombre"], "embedding": r["embedding"].tolist()}
        for r in db
    ]
    with open(DB_PATH, "w", encoding="utf-8") as f:
        json.dump(serializable, f, ensure_ascii=False, indent=2)


def main():
    if not os.path.exists(DETECTOR_PATH) or not os.path.exists(RECOGNIZER_PATH):
        print("Faltan los modelos ONNX en", MODELS_DIR)
        return

    detector = cv2.FaceDetectorYN_create(DETECTOR_PATH, "", (FRAME_W, FRAME_H), score_threshold=0.7)
    recognizer = cv2.FaceRecognizerSF_create(RECOGNIZER_PATH, "")

    db = cargar_db()
    print(f"Colaboradores enrolados: {len(db)}")

    cap = cv2.VideoCapture(0, cv2.CAP_DSHOW)
    if not cap.isOpened():
        print("No se pudo abrir la camara (indice 0).")
        return
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, FRAME_W)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, FRAME_H)

    reconociendo = False
    ultimo_marcado = {}  # dni -> timestamp

    window = "Asistencia - Reconocimiento Facial (prototipo)"
    cv2.namedWindow(window)

    print("\nListo. E=enrolar  R=reconocer on/off  L=listar  Q/ESC=salir\n")

    while True:
        ok, frame = cap.read()
        if not ok:
            print("No se pudo leer frame de la camara.")
            break

        h, w = frame.shape[:2]
        detector.setInputSize((w, h))
        _, faces = detector.detect(frame)

        mejor_cara = None
        if faces is not None and len(faces) > 0:
            # La cara mas grande (area del bbox), por si hay varias personas.
            mejor_cara = max(faces, key=lambda f: f[2] * f[3])

        if mejor_cara is not None:
            x, y, bw, bh = mejor_cara[:4].astype(int)
            color = (100, 100, 100)
            label = ""

            if reconociendo and db:
                aligned = recognizer.alignCrop(frame, mejor_cara)
                emb = recognizer.feature(aligned)
                mejor_match, mejor_score = None, -1.0
                for r in db:
                    score = recognizer.match(emb, r["embedding"].reshape(1, -1), cv2.FaceRecognizerSF_FR_COSINE)
                    if score > mejor_score:
                        mejor_score = score
                        mejor_match = r
                if mejor_score >= COSINE_THRESHOLD:
                    color = (0, 200, 0)
                    label = f"{mejor_match['nombre']} ({mejor_match['dni']}) sim={mejor_score:.3f}"
                    ahora = time.time()
                    if ahora - ultimo_marcado.get(mejor_match["dni"], 0) > 5:
                        ultimo_marcado[mejor_match["dni"]] = ahora
                        print(f"[MARCACION] {time.strftime('%H:%M:%S')} - {mejor_match['nombre']} ({mejor_match['dni']}) sim={mejor_score:.3f}")
                else:
                    color = (0, 0, 220)
                    label = f"No reconocido (sim={mejor_score:.3f})"

            cv2.rectangle(frame, (x, y), (x + bw, y + bh), color, 2)
            if label:
                cv2.rectangle(frame, (x, y - 24), (x + max(bw, 260), y), color, -1)
                cv2.putText(frame, label, (x + 4, y - 6), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 255), 1, cv2.LINE_AA)

        estado = f"Enrolados: {len(db)}  |  Reconocer: {'ON' if reconociendo else 'OFF'}  |  E=enrolar R=reconocer L=listar Q=salir"
        cv2.rectangle(frame, (0, h - 26), (w, h), (30, 30, 30), -1)
        cv2.putText(frame, estado, (6, h - 8), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (230, 230, 230), 1, cv2.LINE_AA)

        cv2.imshow(window, frame)
        key = cv2.waitKey(1) & 0xFF

        if key in (ord("q"), ord("Q"), 27):
            break

        elif key in (ord("r"), ord("R")):
            reconociendo = not reconociendo
            print(f"Reconocimiento {'activado' if reconociendo else 'desactivado'}.")

        elif key in (ord("l"), ord("L")):
            print(f"\n--- Colaboradores enrolados ({len(db)}) ---")
            for r in db:
                print(f"  {r['dni']}  {r['nombre']}")
            print("---\n")

        elif key in (ord("e"), ord("E")):
            if mejor_cara is None:
                print("No se detecta ningun rostro para enrolar. Acercate a la camara.")
                continue
            dni = input("DNI del colaborador: ").strip()
            nombre = input("Nombre completo: ").strip()
            if not dni or not nombre:
                print("DNI/nombre vacio, se cancela el enrolamiento.")
                continue

            muestras = []
            for i in range(ENROLL_SAMPLES):
                ok, f2 = cap.read()
                if not ok:
                    continue
                h2, w2 = f2.shape[:2]
                detector.setInputSize((w2, h2))
                _, faces2 = detector.detect(f2)
                if faces2 is None or len(faces2) == 0:
                    print(f"  muestra {i+1}: no se detecto rostro, se omite.")
                    continue
                cara2 = max(faces2, key=lambda f: f[2] * f[3])
                aligned2 = recognizer.alignCrop(f2, cara2)
                emb2 = recognizer.feature(aligned2)
                muestras.append(emb2)
                print(f"  muestra {i+1}/{ENROLL_SAMPLES} capturada.")
                cv2.waitKey(300)

            if not muestras:
                print("No se pudo capturar ninguna muestra valida.")
                continue

            promedio = np.mean(np.vstack(muestras), axis=0).astype(np.float32)
            db = [r for r in db if r["dni"] != dni]
            db.append({"dni": dni, "nombre": nombre, "embedding": promedio})
            guardar_db(db)
            print(f"Enrolado: {nombre} ({dni}). Total enrolados: {len(db)}\n")

    cap.release()
    cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
