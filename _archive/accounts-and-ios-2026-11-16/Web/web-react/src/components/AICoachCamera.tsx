import React, { useRef, useEffect, useState } from 'react';

interface AICoachCameraProps {
  exerciseName: string;
  onClose: () => void;
}

const AICoachCamera: React.FC<AICoachCameraProps> = ({ exerciseName, onClose }) => {
  const videoRef = useRef<HTMLVideoElement>(null);
  const [hasPermission, setHasPermission] = useState<boolean | null>(null);
  const [feedback, setFeedback] = useState<string>("Analyzing your form...");
  const [aiModel, setAiModel] = useState<string>('Cerebras');
  const [repCount, setRepCount] = useState<number>(0);

  useEffect(() => {
    // Check for selected BatesAI model from simulated global state/localStorage
    const savedModel = localStorage.getItem('batesAI_selectedModel');
    if (savedModel) {
      setAiModel(savedModel);
    }

    let stream: MediaStream | null = null;

    const startCamera = async () => {
      try {
        stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'user' } });
        if (videoRef.current) {
          videoRef.current.srcObject = stream;
        }
        setHasPermission(true);
      } catch (err) {
        console.error("Camera access denied:", err);
        setHasPermission(false);
      }
    };

    startCamera();

    // Simulated AI coaching feedback loop based on the selected model
    const interval = setInterval(() => {
      const messages = [
        "Keep your core tight!",
        "Great depth on that rep.",
        "Slow down the eccentric portion.",
        "Explode up!",
        "Watch your knee tracking.",
        "Perfect form."
      ];
      const randomMsg = messages[Math.floor(Math.random() * messages.length)];
      
      // Simulate rep counting
      if (Math.random() > 0.5) {
        setRepCount(prev => prev + 1);
      }

      setFeedback(`[${aiModel} Analysis]: ${randomMsg}`);
    }, 4000);

    return () => {
      if (stream) {
        stream.getTracks().forEach(track => track.stop());
      }
      clearInterval(interval);
    };
  }, [aiModel]);

  return (
    <div className="ai-coach-overlay">
      <div className="ai-coach-header">
        <h3>Live Coaching: {exerciseName}</h3>
        <span className="model-badge">{aiModel} Powered</span>
        <button className="close-btn" onClick={onClose}>&times;</button>
      </div>
      
      <div className="video-container">
        {hasPermission === false ? (
          <div className="camera-error">
            <p>Camera access is required for live coaching.</p>
            <button onClick={() => window.location.reload()}>Grant Permission</button>
          </div>
        ) : (
          <video 
            ref={videoRef} 
            autoPlay 
            playsInline 
            muted 
            className="camera-feed"
          />
        )}
        
        {/* Simulated pose tracking overlay */}
        {hasPermission && (
          <div className="pose-overlay">
            <div className="tracking-box"></div>
          </div>
        )}
      </div>

      <div className="coaching-panel">
        <div className="rep-counter">
          <span className="rep-number">{repCount}</span>
          <span className="rep-label">Reps Detected</span>
        </div>
        <div className="feedback-box">
          <p>{feedback}</p>
        </div>
      </div>
    </div>
  );
};

export default AICoachCamera;
