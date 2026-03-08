import cv2
import numpy as np
import tensorflow as tf

LABELS = {0: "person", 61: "cake"}  # add more as needed, or load from file

model_path = "assets/models/efficientdet.tflite"
interpreter = tf.lite.Interpreter(model_path=model_path)
input_details = interpreter.get_input_details()
interpreter.resize_tensor_input(input_details[0]['index'], [1, 320, 320, 3])
interpreter.allocate_tensors()
output_details = interpreter.get_output_details()

SCORE_THRESHOLD = 0.5
IOU_THRESHOLD = 0.5

def compute_iou(box, boxes):
    y1 = np.maximum(box[0], boxes[:, 0])
    x1 = np.maximum(box[1], boxes[:, 1])
    y2 = np.minimum(box[2], boxes[:, 2])
    x2 = np.minimum(box[3], boxes[:, 3])
    intersection = np.maximum(0, y2 - y1) * np.maximum(0, x2 - x1)
    box_area = (box[2] - box[0]) * (box[3] - box[1])
    boxes_area = (boxes[:, 2] - boxes[:, 0]) * (boxes[:, 3] - boxes[:, 1])
    return intersection / (box_area + boxes_area - intersection)

def nms(boxes, scores, iou_threshold=IOU_THRESHOLD):
    indices = np.argsort(scores)[::-1]
    keep = []
    while len(indices) > 0:
        current = indices[0]
        keep.append(current)
        if len(indices) == 1:
            break
        ious = compute_iou(boxes[current], boxes[indices[1:]])
        indices = indices[1:][ious < iou_threshold]
    return keep

cap = cv2.VideoCapture(0)
print("Starting Camera... Press 'q' to quit.")

while cap.isOpened():
    ret, frame = cap.read()
    if not ret:
        break

    input_img = cv2.resize(frame, (320, 320))
    input_img = cv2.cvtColor(input_img, cv2.COLOR_BGR2RGB)
    input_data = np.expand_dims(input_img.astype(np.uint8), axis=0)

    interpreter.set_tensor(input_details[0]['index'], input_data)
    interpreter.invoke()

    boxes   = interpreter.get_tensor(output_details[0]['index'])[0]   # (25, 4)
    classes = interpreter.get_tensor(output_details[1]['index'])[0]   # (25,)
    scores  = interpreter.get_tensor(output_details[2]['index'])[0]   # (25,)

    # Filter by confidence, then apply NMS
    valid = np.where(scores > SCORE_THRESHOLD)[0]
    kept = nms(boxes[valid], scores[valid])

    h, w, _ = frame.shape
    for i in kept:
        idx = valid[i]
        ymin, xmin, ymax, xmax = boxes[idx]
        x1, y1, x2, y2 = int(xmin*w), int(ymin*h), int(xmax*w), int(ymax*h)
        label = LABELS.get(int(classes[idx]), f"class {int(classes[idx])}")
        score = scores[idx]
        cv2.rectangle(frame, (x1, y1), (x2, y2), (0, 255, 0), 2)
        cv2.putText(frame, f"{label} {score:.2f}", (x1, y1 - 10),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 2)

    cv2.imshow('TFLite Detection', frame)
    if cv2.waitKey(1) & 0xFF == ord('q'):
        break

cap.release()
cv2.destroyAllWindows()