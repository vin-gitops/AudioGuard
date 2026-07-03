```mermaid
flowchart LR

    A[Audio Sample Input] --> B[Sign Bit Extractor]
    B --> C[Previous Sample Register]
    C --> D[XOR Comparator]
    D --> E[Zero-Crossing Detector]
    E --> F[Crossing Counter]

    A --> G[Sample Counter]
    G --> H{Window Complete?}

    F --> I[Threshold Comparator]
    H --> I

    I -->|Above Threshold| J[Alert Register]
    J --> K[alert_flag]

    H --> L[FSM Controller]
    L --> F
    L --> G
    L --> J
```
