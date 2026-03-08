import cv2
import numpy as np
import tensorflow as tf

# 1. Load the TFLite model and allocate tensors.
model_path = "assets/models/efficientdet.tflite"
interpreter = tf.lite.Interpreter(model_path=model_path)

# If your model is dynamic [1, -1, -1, 3], we force it to 320x320 here
input_details = interpreter.get_input_details()
interpreter.resize_tensor_input(input_details[0]['index'], [1, 320, 320, 3])
interpreter.allocate_tensors()

output_details = interpreter.get_output_details()

# 2. Setup Camera
cap = cv2.VideoCapture(0)

print("Starting Camera... Press 'q' to quit.")

while cap.isOpened():
    ret, frame = cap.read()
    if not ret:
        break

    # 3. Preprocess the image
    # Resize to 320x320
    input_img = cv2.resize(frame, (320, 320))
    input_img = cv2.cvtColor(input_img, cv2.COLOR_BGR2RGB)
    
    # Expand dims to [1, 320, 320, 3]
    input_data = np.expand_dims(input_img, axis=0)

    # Keep the pixels as 0-255 integers
    input_data = input_img.astype(np.uint8)
    input_data = np.expand_dims(input_data, axis=0)

    # 4. Run Inference
    interpreter.set_tensor(input_details[0]['index'], input_data)
    interpreter.invoke()

    # 5. Print Raw Outputs to see what you're dealing with
    print("\n--- New Frame ---")
    for i in range(len(output_details)):
        output_data = interpreter.get_tensor(output_details[i]['index'])
        print(f"Output {i} Shape: {output_data.shape}")
        # Print first few values of each output to identify Boxes vs Scores
        print(f"Output {i} Data sample: {output_data.flatten()[:5]}")

    # Display the camera feed
    cv2.imshow('TFLite Test', frame)
    if cv2.waitKey(1) & 0xFF == ord('q'):
        break

cap.release()
cv2.destroyAllWindows()