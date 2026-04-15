# Pipeline per la ricostruzione e registrazione della centerline del colon<br> 



## Descrizione generale

Questo repository contiene una pipeline in MATLAB, sviluppata in due parti, per:

- ricostruire il lume interno del colon a partire da segmentazioni volumetriche
- estrarre una centerline geometricamente centrata
- regolarizzare la traiettoria per simulazioni
- registrare la traiettoria finale sul modello STL originale del colon


Il workflow combina:
- **3D Slicer** per il preprocessing geometrico e la generazione degli input volumetrici
- **MATLAB** per la ricostruzione del lume, il calcolo della centerline, la validazione quantitativa e la registrazione finale sullo STL originale


## 3D Slicer


In 3D Slicer ho eseguito tre operazioni PRINCIPALI:

### 1. Costruzione di una rappresentazione volumetrica del colon

Si è passati da una mesh superficiale a una segmentazione voxelizzata del colon, cioè a una rappresentazione 3D discreta in cui ogni voxel appartiene oppure no alla struttura.

### 2. Definizione di una shell chiusa del colon

Ho costruito una parete chiusa del colon, in modo da poter distinguere chiaramente:
- esterno
- parete
- interno

Questo passaggio era necessario per poter ricostruire in MATLAB il lume interno.

### 3. Creazione di due cap separati

Ho creato due cap distinti:
- `CAP_1`
- `CAP_2`

Questi cap servono come marker geometrici delle due aperture del colon.

In pratica impongono all’algoritmo le due condizioni al bordo della traiettoria:
- la centerline deve iniziare in corrispondenza di una apertura
- la centerline deve terminare in corrispondenza dell’altra apertura

### Output esportati da 3D Slicer

Da Slicer sono stati esportati tre volumi:
- la shell del colon voxelizzata
- il cap della prima estremità
- il cap della seconda estremità


---




## MATLAB

La pipeline in matlab è composta da due parti_.

### Parte 1 — Ricostruzione della centerline

Script:
`compute_centerline_part1.m`

#### Input
- `Segmentation_colon-colonShell_2-label.nii`
- `Segmentation_colon-Cap_1-label.nii`
- `Segmentation_colon-Cap_2-label_1.nii`

#### Logica della parte 1
1. lettura dei volumi NIfTI (esportati da 3D Slicer)
2. costruzione della shell chiusa del colon tramite unione di shell e cap
3. ricostruzione del lume interno mediante flood fill dell’esterno
4. calcolo della distance transform del lume
5. stima di centroide e normale dei due cap
6. individuazione di due anchor interni al lume a partire dai cap
7. estrazione dello skeleton del lume
8. selezione della componente principale dello skeleton
9. costruzione di un grafo pesato sui voxel dello skeleton
10. calcolo dello shortest path tra i due estremi
11. costruzione della centerline grezza
12. smoothing e ricampionamento uniforme
13. generazione di una traiettoria ulteriormente regolarizzata per navigazione
14. validazione quantitativa della traiettoria

#### Output principale
- `centerline_from_caps.mat`


---

### Parte 2 — Registrazione della centerline sullo STL originale

Script:
`register_centerline_to_stl_part2.m`

#### Input
- `centerline_from_caps.mat`
- `colon_open.stl`

#### Logica della parte 2
1. caricamento dei risultati della parte 1
2. estrazione di una mesh triangolare dalla segmentazione del colon
3. trasformazione della mesh e della centerline dal sistema voxel al sistema fisico NIfTI
4. caricamento dello STL originale
5. applicazione di una permutazione degli assi e di un flip dei segni, identificati come ottimali per il dataset
6. raffinamento finale dell’allineamento tramite ICP
7. applicazione della trasformazione finale alla mesh e alla centerline
8. visualizzazione dell’overlay tra mesh registrata e STL originale
9. visualizzazione finale di STL e centerline registrata
10. costruzione di un tubo sottile attorno alla centerline
11. esportazione finale degli STL

#### Output principali
- `centerline_caps_final_registered.mat`
- `colon_registered.stl`
- `centerline_tube_thin.stl`

---

### Obs:

1) Inizialmene avevo eseguito una ricerca automatica su:
- tutte le 6 permutazioni degli assi
- tutti gli 8 flip possibili dei segni

per un totale di 48 configurazioni iniziali.

Per ciascuna configurazione:
- veniva applicata permutazione e flip alla mesh segmentata
- i punti venivano centrati sui rispettivi centroidi
- veniva eseguito ICP contro lo STL originale
- si confrontava l’RMSE finale

Ho trovato che la configurazione migliore è risultata essere :
- `perm = [2 3 1]`
- `flip = [-1 1 1]`

Ho quindi fissato questa configurazione direttamente nello script finale.

2)Devo migliorare i 3 volumi su slicer3D !!!!

