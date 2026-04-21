%% ============================================================
%  PARTE 1 - RICOSTRUZIONE CENTERLINE 
%% ============================================================


%INPUT:
%   - Segmentation_colon-colonShell_2-label.nii --> shell del colon segmentata in 3D Slicer
%   - Segmentation_colon-Cap_1-label.nii --> primo tappo di chiusura applicato a una estremità
%   - Segmentation_colon-Cap_2-label_1.nii --> secondo tappo di chiusura applicato all’altra estremità
%   - colon_open.stl  -->> mesh STL originale del colon aperto 
%
% OUTPUT:
%   - centerline_caps_final.mat
%    -->file MATLAB contenente:
%       * BWclosed      = volume chiuso del colon
%       * BWlumen       = lume interno ricostruito
%       * D             = distance transform del lume
%       * anchor1/2     = punti iniziale e finale interni al lume
%       * SkelMain      = skeleton principale del lume
%       * cl_raw        = centerline grezza
%       * cl_resampled  = centerline 
%       * cl_nav        = traiettoria regolarizzata per navigazione
%       * metriche di validazione (lunghezza, centralità, punti interni, roughness)
%% ============================================================


clear; clc; close all;



%% ------------------------------------------------------------
% STEP 1 - Nomi file
%% ------------------------------------------------------------


% INPUT
fnameShell = fullfile('INPUT','Segmentation_colon-colonShell_2-label.nii');
fnameCap1  = fullfile('INPUT','Segmentation_colon-Cap_1-label.nii');
fnameCap2  = fullfile('INPUT','Segmentation_colon-Cap_2-label_1.nii');

% OUTPUT
outMAT = fullfile('OUTPUT_CENTERLINE','centerline_from_caps.mat');


%% ------------------------------------------------------------
% STEP 2 - Lettura volumi
%% ------------------------------------------------------------


Vshell = niftiread(fnameShell);
Vcap1  = niftiread(fnameCap1);
Vcap2  = niftiread(fnameCap2);
infoShell = niftiinfo(fnameShell);

%trasformo i volumi in volumi logici binari(se voxel=1 appartiene alla
%struttura se =0 è lo sfondo)
BWshell = Vshell > 0;  %-->Shell binaria
CAP1    = Vcap1  > 0;  %-->Cap1 binario
CAP2    = Vcap2  > 0;  %-->Cap2 binario

voxSize = infoShell.PixelDimensions(1:3);
%stampo i numeri che mi dicono quanti voxel appartengono a ciascun
%oggetto(shell colon/cap1/cap2)

fprintf('==================== INPUT ====================\n');
fprintf('Voxel shell: %d | CAP1: %d | CAP2: %d\n', ...
        nnz(BWshell), nnz(CAP1), nnz(CAP2));


%% ------------------------------------------------------------
% STEP 3 - Shell chiusa
%% ------------------------------------------------------------


%costruisco la superficie chiusa finale del colon--> il colon viene reso chiuso da shell+cap1+cap2
BWclosed = BWshell | CAP1 | CAP2; %Volume binario del colon chiuso: se voxel=1 appartiene alla struttura, 0 non
%appartiene alla struttura
fprintf('Voxel shell chiusa: %d\n', nnz(BWclosed));


%% ------------------------------------------------------------
% STEP 4 - Ricostruzione lume
%% ------------------------------------------------------------

% Ispessisco leggermente la barriera per chiudere piccoli gap voxel
BWbarrier = imdilate(BWclosed, strel('sphere',1));
%Aggiungo un bordo di spessore 1 voxel attorno a tutto il volume
BWpad = padarray(BWbarrier, [1 1 1], 0, 'both');
%Marker:maschera che contiene un solo punto acceso(1)
% creo un volume vuoto(=0) della stessa dimensione di BWpad
marker = false(size(BWpad));
marker(1,1,1) = true;%metto a 1 solo un voxel--> questo voxel viene usato come seme dell'esterno

%outside: volume binario del dominio esterno al colon:
%1=voxel esterni
%0=voxel interni alla shell
outside = imreconstruct(marker, ~BWpad, 6);

%Ricavo il lume (l'interno del colon)
BWlumen_pad = ~(outside | BWpad);  %-->ottengo il lumen come complemento della shell chiusa+regione esterna
%BWlumen: lume nelle dimensioni originali
BWlumen = BWlumen_pad(2:end-1, 2:end-1, 2:end-1);%rimozione padding

%Pulizia del lume
CC = bwconncomp(BWlumen, 6);
numPix = cellfun(@numel, CC.PixelIdxList);

if isempty(numPix)
    error('Nessun lume trovato.');
end

BWtmp = false(size(BWlumen));
[~, idxL] = max(numPix);
BWtmp(CC.PixelIdxList{idxL}) = true;
BWlumen = BWtmp;  %bwlumen è la maschera binaria del lume interno

%stampo il numero di voxel del dominio interno attraversabile
fprintf('Voxel lume: %d\n', nnz(BWlumen));


%% ------------------------------------------------------------
% STEP 5 - Distance transform
%% ------------------------------------------------------------


%D=Distance transform del lume: mappa che contiene la distanza ,per ogni voxel del lume, dalla parete più vicina
% --> un valore grande di D significa che il punto è centrale
%--> un valore piccolo di D significa che il punto è vicino alla parete
D = bwdist(~BWlumen);
fprintf('Max D: %.3f voxel\n', max(D(:)));
%D(i,j,k)=A significa che il voxel (i,j,k) è lontano A dalla parete --> OBS D è in voxel e ha le stesse dimensioni di BWlumen


%% ------------------------------------------------------------
% STEP 6 - Geometria dei cap
%% ------------------------------------------------------------


%Per i due CAP ricavo centroide e normale per capire dove si trova
%l'apertura e in quale direzione entrare nel lume
%Quindi per ogni tappo ottengo:
%-un punto centrale
%-una direzione perpendicolare al tappo
cCap1 = getCentroid(CAP1);  %-->Rappresenta il punto di partenza per cercare l’anchor
cCap2 = getCentroid(CAP2);

nCap1 = getCapNormalPCA(CAP1); %--> stimo la direzione perpendicolare al cap
nCap2 = getCapNormalPCA(CAP2);

fprintf('\nCentroide CAP1: [%.2f %.2f %.2f]\n', cCap1);
fprintf('Centroide CAP2: [%.2f %.2f %.2f]\n', cCap2);
fprintf('Normale CAP1:   [%.4f %.4f %.4f]\n', nCap1);
fprintf('Normale CAP2:   [%.4f %.4f %.4f]\n', nCap2);


%% ------------------------------------------------------------
% STEP 7 - Anchor dai cap usando la NORMALE:gli anchor sono i due punti estremi interni al lume da cui far partire/finire centerline
%
% -parte dal centroide del Cap
% -prova a muoversi lungo la normale
% -cerca in quale verso si entra nel lume
% -appena entra nel lume trova un primo punto interno
% -attorno a quel punto costruisce una piccola regione locale
%-dentro quella regione sceglie il voxel con D massima--> questo voxel è l'anchor
%% ------------------------------------------------------------


[anchor1, adjCap1, ray1] = getAnchorFromCapNormal(CAP1, BWlumen, D, cCap1, nCap1, 'CAP1');
[anchor2, adjCap2, ray2] = getAnchorFromCapNormal(CAP2, BWlumen, D, cCap2, nCap2, 'CAP2');

fprintf('\nAnchor1: [%d %d %d] D=%.2f\n', anchor1, D(anchor1(1),anchor1(2),anchor1(3)));
fprintf('Anchor2: [%d %d %d] D=%.2f\n', anchor2, D(anchor2(1),anchor2(2),anchor2(3)));


%% ------------------------------------------------------------
% STEP 8 - Diagnostica anchor MIGLIORATA
%% ------------------------------------------------------------


figure('Name','DIAGNOSTICA: cap, normali e anchor','Color','w');

% lume trasparente
ph = patch(isosurface(BWlumen,0.5));
isonormals(BWlumen,ph);
set(ph,'FaceColor',[0.75 0.80 1.00], ...
       'EdgeColor','none', ...
       'FaceAlpha',0.05);
hold on;

% --- visualizzazione CAP come superfici invece che come nuvole di voxel
if any(CAP1(:))
    p1 = patch(isosurface(CAP1,0.5));
    isonormals(CAP1,p1);
    set(p1,'FaceColor',[0 0.8 0], ...
           'EdgeColor','none', ...
           'FaceAlpha',0.35);
end

if any(CAP2(:))
    p2 = patch(isosurface(CAP2,0.5));
    isonormals(CAP2,p2);
    set(p2,'FaceColor',[0 0 1], ...
           'EdgeColor','none', ...
           'FaceAlpha',0.35);
end

% centroidi
plot3(cCap1(2), cCap1(1), cCap1(3), 'g+', ...
    'MarkerSize', 16, 'LineWidth', 3);
plot3(cCap2(2), cCap2(1), cCap2(3), 'b+', ...
    'MarkerSize', 16, 'LineWidth', 3);

% anchor
plot3(anchor1(2), anchor1(1), anchor1(3), 'go', ...
    'MarkerFaceColor','g', 'MarkerSize',10, 'LineWidth',2);
plot3(anchor2(2), anchor2(1), anchor2(3), 'bo', ...
    'MarkerFaceColor','b', 'MarkerSize',10, 'LineWidth',2);

% raggi usati per entrare nel lume
if ~isempty(ray1)
    plot3(ray1(:,2), ray1(:,1), ray1(:,3), ...
        '-', 'Color',[0 0.7 0], 'LineWidth',2.5);
end
if ~isempty(ray2)
    plot3(ray2(:,2), ray2(:,1), ray2(:,3), ...
        '-', 'Color',[0 0 0.9], 'LineWidth',2.5);
end

% normali come frecce
scaleN = 25;
quiver3(cCap1(2), cCap1(1), cCap1(3), ...
        scaleN*nCap1(2), scaleN*nCap1(1), scaleN*nCap1(3), ...
        0, 'Color',[0 0.6 0], 'LineWidth',2, 'MaxHeadSize',1.2);

quiver3(cCap2(2), cCap2(1), cCap2(3), ...
        scaleN*nCap2(2), scaleN*nCap2(1), scaleN*nCap2(3), ...
        0, 'Color',[0 0 0.8], 'LineWidth',2, 'MaxHeadSize',1.2);

% etichette testuali
text(cCap1(2), cCap1(1), cCap1(3), '  C1', ...
    'Color',[0 0.5 0], 'FontSize',11, 'FontWeight','bold');
text(cCap2(2), cCap2(1), cCap2(3), '  C2', ...
    'Color',[0 0 0.7], 'FontSize',11, 'FontWeight','bold');

text(anchor1(2), anchor1(1), anchor1(3), '  A1', ...
    'Color',[0 0.5 0], 'FontSize',11, 'FontWeight','bold');
text(anchor2(2), anchor2(1), anchor2(3), '  A2', ...
    'Color',[0 0 0.7], 'FontSize',11, 'FontWeight','bold');

daspect([1 1 1]);
axis tight;
axis vis3d;
view(135,25);
camlight headlight;
lighting gouraud;
grid on;

title({
    'Diagnostica anchor',
    sprintf('A1 D=%.2f | A2 D=%.2f', ...
    D(anchor1(1),anchor1(2),anchor1(3)), ...
    D(anchor2(1),anchor2(2),anchor2(3)))
});

hold off;


%% ------------------------------------------------------------
% STEP 9 - Skeleton del lume
%% ------------------------------------------------------------


%Calcolo lo skeleton 3D del volume binario
minBranch = 15;%elimino rami molto piccoli
Skel = bwskel(BWlumen, 'MinBranchLength', minBranch); %--> ottengo lo skeleton che è una rappresentazione molto più sottile di bwlume

if ~any(Skel(:))
    error('Skeleton vuoto.');
end

CCs = bwconncomp(Skel, 26);%tengo solo la componente principale-->la componente principale rappresenta il percorso principale del lume
numPixS = cellfun(@numel, CCs.PixelIdxList);

SkelMain = false(size(Skel));
[~, idxS] = max(numPixS);   %trovo la componente dello skeleton più grande 
SkelMain(CCs.PixelIdxList{idxS}) = true;

fprintf('\nVoxel skeleton: %d\n', nnz(SkelMain)); %stampo i voxel che compongono lo skeleton principale
%--> Skel:È lo skeleton 3D completo del lume, dopo la rimozione dei rametti più corti di minBranch
%-->SkelMain:È  la componente connessa più grande dello skeleton (che poi utilizzo per fare il grafo)
%--> Ho usato gli anchor proprio per non far dipendere gli estremi della centerline dagli endpoint grezzi skeleton, che vicino alle aperture rrisultavano essere troppo spinti verso il fondo e non ben centrati.


%% ------------------------------------------------------------
% STEP 10 - Grafo pesato dello skeleton
%-ogni voxel dello skeleton diventa un nodo
%-due voxel vicini vengono collegati con un arco
%-a ogni arco assegno un peso
%-il peso è costruito in modo da favorire le zone più centrali del lume
%-poi faccio shortest path sul grafo
%% ------------------------------------------------------------

%Ogni voxel dello skeleton SkelMain diventa un nodo del gafo
skelIdx = find(SkelMain); %restituisco gli indici lineari di tutti i voxel dello skeleton principale
nNodes  = numel(skelIdx); %numero totale di nodi del grafo
%trasformo ogni indice lineare nelle coordinate voxel
[xs, ys, zs] = ind2sub(size(SkelMain), skelIdx);
coords = [xs ys zs];
Dvals  = D(skelIdx);  %valore della distance transform in quel voxel skeleton

%faccio una corrispondenza veloce tra:
%-indice lineare del voxel nello spazio 3D
%-indice del nodo nel grafo
%es: lin2node(15328) = 47 vuol dire: il voxel con indice lineare 15328 corrisponde al nodo 47 del grafo
lin2node = containers.Map('KeyType','uint32','ValueType','uint32');
for i = 1:nNodes
    lin2node(uint32(skelIdx(i))) = uint32(i);
end
%offsets è la lista dei possibili vicini di ciascun nodo
offsets = [];
for dx = -1:1
    for dy = -1:1
        for dz = -1:1
            if ~(dx == 0 && dy == 0 && dz == 0)
                offsets = [offsets; dx dy dz]; 
            end
        end
    end
end

%Vettori che conterranno gli archi
I_ = []; %nodo di partenza dell'arco
J_ = []; %nodo di arrivo dell'arco
W_ = []; %peso dell'arco

szV   = size(SkelMain);
alpha = 2.0;  %parametro che favorisce la centralità (maggiore è alpha, più il peso dipende da D)
epsW  = 0.5;
%ciclo su tutti i nodi
for i = 1:nNodes
%ciclo sui vicini
    for k = 1:size(offsets,1)
        xn = coords(i,1) + offsets(k,1);
        yn = coords(i,2) + offsets(k,2);
        zn = coords(i,3) + offsets(k,3);

        if xn < 1 || yn < 1 || zn < 1 || ...
           xn > szV(1) || yn > szV(2) || zn > szV(3)
            continue;
        end
%converto il vicino in indice lineare
        linN = sub2ind(szV, xn, yn, zn);
%Controllo che il vicino appartenga allo skeleton: se on lo è,allora non è un nodo del grafo e non creo nessun arco--> collego solo voxel skeleton vinini tra loro
        if ~SkelMain(linN)
            continue;
        end
%Recupero il numero del nodo vicino
        j = double(lin2node(uint32(linN)));
        if j <= i
            continue;
        end
%calcolo la lunghezza dell'arco
        dij   = norm(offsets(k,:));
        %dmean misura quanto quell’arco si trova in una zona centrale del lume.
        dmean = 0.5 * (Dvals(i) + D(linN));
        %Il peso dell’arco cresce con la distanza geometrica dij e diminuisce con la centralità dmean
        wij   = dij / (dmean + epsW)^alpha; . 
       

        I_(end+1,1) = i; 
        J_(end+1,1) = j; 
        W_(end+1,1) = wij; 
    end
end

G = graph(I_, J_, W_);%--> grafo pesato dello skeleton
%--> Ho costruito un grafo in cui:
%-ogni voxel skeleton è un nodo
%-due voxel adiacenti sono connessi
%-ogni connessione costa meno se passa in zone più centrali del lume


%% ------------------------------------------------------------
% STEP 11 - Aggancio anchor allo skeleton
%per ciascun anchor(che noon necessariamente sono voxel dello skeleton) cerco alcuni nodi skeleton vicini, 
%poi scelgo quello migliore come compromesso tra essere vicino all’anchor ed essere centrale nel lume
%% ------------------------------------------------------------


%Calcolo la distanza di ogni nodo skeleton dagli anchor
dStart = sqrt(sum((coords - anchor1).^2, 2));
dEnd   = sqrt(sum((coords - anchor2).^2, 2));

kNear = 30; %considero solo i 30 nodi dello skeleton più vicini agli anchor
%ordino questi nodi per distanza crescente
[~, ordS] = sort(dStart, 'ascend');
[~, ordE] = sort(dEnd,   'ascend');

candS = ordS(1:min(kNear, numel(ordS))); %--> fino a 30 nodi skeleton più vicini ad anchor1
candE = ordE(1:min(kNear, numel(ordE))); %-->fino a 30 nodi skeleton più vicini ad anchor2

%Recupero le distanze dei candidati
distS = dStart(candS);
distE = dEnd(candE);
%Normalizzo le distanze
distS_n = distS / (max(distS) + eps);
distE_n = distE / (max(distE) + eps);
%Normalizzo anche la centralità D
DvalsS_n = Dvals(candS) / (max(Dvals(candS)) + eps);
DvalsE_n = Dvals(candE) / (max(Dvals(candE)) + eps);

%per ogni candidato controllo vicinanza e centralità dando il 60% importanza alla centralità e 40% importanza alla vicinanza--> premio la centralità e penalizzo la distanza
scoreS = 0.6 * DvalsS_n - 0.4 * distS_n;
scoreE = 0.6 * DvalsE_n - 0.4 * distE_n;
%trovo il miglior candidato tra i 30 vicini
[~, iBestS] = max(scoreS);
[~, iBestE] = max(scoreE);

%nodi iniziali e finali dello shortest path
nodeStart = candS(iBestS);  %-->nodo dello skeleton scelto come inizio del path
nodeEnd   = candE(iBestE);  %-->nodo dello skeleton scelto come fine del path

fprintf('Nodo skeleton start: [%d %d %d] | D=%.2f\n', ...
        coords(nodeStart,1), coords(nodeStart,2), coords(nodeStart,3), Dvals(nodeStart));
fprintf('Nodo skeleton end  : [%d %d %d] | D=%.2f\n', ...
        coords(nodeEnd,1), coords(nodeEnd,2), coords(nodeEnd,3), Dvals(nodeEnd));


%% ------------------------------------------------------------
% STEP 12 - Shortest path--> Dal grafo dello skeleton, ottiengo il percorso centrale ordinato tra inizio e fine.
%% ------------------------------------------------------------


%shortestpath seleziona tra tutti i possibili percorsi che collegano nodeStart e nodeEnd sullo skeleton  quello con costo totale minimo.
%--> Dato che i pesi degli archi penalizzano le zone meno centrali, il percorso minimo tende a passare dove D è più alta.
[bestPath, bestCost] = shortestpath(G, nodeStart, nodeEnd); %obs: bestPath è un vettore di indici di nodo del grafo e bestCost è la somma dei wij lungo tutti gli archi del path

if isempty(bestPath)
    error('Nessun path trovato.');
end

centerline_vox = coords(bestPath,:);  %Conversione del path in coordinate voxel
fprintf('Path: %d punti | costo = %.6f\n', numel(bestPath), bestCost);



%% ------------------------------------------------------------
% STEP 13 - Centerline completa
%% ------------------------------------------------------------


cl_raw = [anchor1; centerline_vox; anchor2]; %centerline grezza:metto insieme centerline_vox e i due anchor



%% ------------------------------------------------------------
% STEP 14 - Smooth
%% ------------------------------------------------------------


%regolarizzo la curva tramite smoothing
% prima faccio un ricampionamento uniforme della curva grezza,
% poi smoothing su punti con distribuzione geometrica più regolare

%calcolo la differenza tra ogni punto e il successivo
diffs_raw0  = diff(cl_raw, 1, 1);
segLen_raw0 = sqrt(sum(diffs_raw0.^2, 2)); %calcolo la lunghezza euclidea di ogni segmento
arcLength_raw0 = [0; cumsum(segLen_raw0)];
%la curva grezza viene prima ricampionata in 300 punti 
% uniformemente distribuiti lungo la lunghezza d’arco

nSamples = 300;  %rappresento la curva con 300 punti
sUniform_raw0 = linspace(0, arcLength_raw0(end), nSamples)'; --> vprendo 300 posizioni uniformemente distribuite lungo la lunghezza della curva

%Primo ricampionamento uniforme con interp1 (obs interpolazione separata per x,y,z)
cl_uniform_first = zeros(nSamples,3);
for k = 1:3
    cl_uniform_first(:,k) = interp1(arcLength_raw0, cl_raw(:,k), sUniform_raw0, 'pchip');
end
%Reimpongo gli estremi
cl_uniform_first(1,:)   = anchor1;
cl_uniform_first(end,:) = anchor2;

%Smoothing coordinata per coordinata usando una media mobile di finestra 11.
win = 11;
cl_smooth = cl_uniform_first;

for k = 1:3
    cl_smooth(:,k) = smoothdata(cl_uniform_first(:,k), 'movmean', win);
end

%reimpongo esplicitamente gli estremi nel caso in cui lo smoothing li abbia spostati
cl_smooth(1,:)   = anchor1;
cl_smooth(end,:) = anchor2;


%% ------------------------------------------------------------
% STEP 15 - Secondo ricampionamento uniforme della centerline
%% ------------------------------------------------------------

%ricampionamento finale
diffs  = diff(cl_smooth, 1, 1);
segLen = sqrt(sum(diffs.^2, 2));
arcLength = [0; cumsum(segLen)];

sUniform = linspace(0, arcLength(end), nSamples)';

cl_resampled = zeros(nSamples,3);
for k = 1:3
    cl_resampled(:,k) = interp1(arcLength, cl_smooth(:,k), sUniform, 'pchip');
end

cl_resampled(1,:)   = anchor1;
cl_resampled(end,:) = anchor2;


%% ------------------------------------------------------------
% STEP 16 - Lunghezza centerline in mm
%% ------------------------------------------------------------


diffs_mm = diff(cl_resampled, 1, 1) .* voxSize;
totalMM  = sum(sqrt(sum(diffs_mm.^2, 2)));
fprintf('Lunghezza centerline: %.2f mm\n', totalMM);


%% ------------------------------------------------------------
% STEP 17 - Validazione quantitativa
%% ------------------------------------------------------------


D_centerline = sampleDistanceOnCurve(D, cl_resampled);%Distance transform di ogni punto della centerline
%Metriche misurano quanto la curva stia mediamente al centro del lum
Dmin    = min(D_centerline);%punto peggiore della centerline
Dmean   = mean(D_centerline);%centralità media lungo tutta la traiettoria
Dmedian = median(D_centerline);%misura robusta della centralità complessiva

fprintf('\n================ VALIDAZIONE ===================\n');
fprintf('D lungo centerline: min=%.2f | mean=%.2f | median=%.2f\n', ...
        Dmin, Dmean, Dmedian);

insideMask = pointsInsideMask(cl_resampled, BWlumen);
insideFrac = mean(insideMask) * 100;
fprintf('Punti della centerline dentro BWlumen: %.2f %%\n', insideFrac);


%% ------------------------------------------------------------
% STEP 18 - Grafico D lungo l'arco 
%% ------------------------------------------------------------

% ascissa in mm lungo la centerline
s_mm = [0; cumsum(sqrt(sum((diff(cl_resampled,1,1).*voxSize).^2,2)))];




%% ------------------------------------------------------------
% STEP 20B - Traiettoria navigata da centerline resampled
% Riduzione dei gradi di libertà + interpolazione spline
%% ------------------------------------------------------------

% cl_resampled = centerline resampled già trovata
% cl_nav       = traiettoria più regolare per navigazione

nCtrlNav = 20;   %20 punti distribuiti lungo la centerline resampled

% punti di controllo presi lungo la centerline resampled
idxCtrl = round(linspace(1, size(cl_resampled,1), nCtrlNav));
idxCtrl = unique(idxCtrl);
ctrlPts = cl_resampled(idxCtrl,:);  %20 punti rappresentativi distribuiti lungo la curva

% assicuro che gli estremi siano gli anchor
ctrlPts(1,:)   = anchor1;
ctrlPts(end,:) = anchor2;

% parametrizzazione a lunghezza d'arco dei punti di controllo
dCtrl = diff(ctrlPts,1,1);
segCtrl = sqrt(sum(dCtrl.^2,2));
sCtrl = [0; cumsum(segCtrl)];

% Interpolazione spline: costruisco la nuova traiettoria cl_nav
%- 20 punti di controllo
%-una spline cubica
%-300 campioni finali
sCtrlUniform = linspace(0, sCtrl(end), nSamples)';
cl_nav = zeros(nSamples,3);
for k = 1:3
    cl_nav(:,k) = interp1(sCtrl, ctrlPts(:,k), sCtrlUniform, 'spline');
end

cl_nav(1,:)   = anchor1;
cl_nav(end,:) = anchor2;

% Validazione della traiettoria navigata
D_nav = sampleDistanceOnCurve(D, cl_nav);
Dmin_nav    = min(D_nav);
Dmean_nav   = mean(D_nav);
Dmedian_nav = median(D_nav);

insideMask_nav = pointsInsideMask(cl_nav, BWlumen);
insideFrac_nav = mean(insideMask_nav) * 100;

diffs_nav_mm = diff(cl_nav, 1, 1) .* voxSize;
totalMM_nav  = sum(sqrt(sum(diffs_nav_mm.^2, 2)));
%Roughness: Misuro quanto la zurva è irregolare
rough_res = curveRoughness(cl_resampled);
rough_nav = curveRoughness(cl_nav);
%calcolo la deviazione tra cl_resempled e cl_nav
dev_nav_vs_res = sqrt(sum((cl_nav - cl_resampled).^2, 2));

fprintf('\n============= TRAIETTORIA NAVIGAZIONE =============\n');
fprintf('nCtrlNav = %d\n', nCtrlNav);
fprintf('Lunghezza traiettoria navigata: %.2f mm\n', totalMM_nav);
fprintf('D lungo traiettoria nav: min=%.2f | mean=%.2f | median=%.2f\n', ...
        Dmin_nav, Dmean_nav, Dmedian_nav);
fprintf('Punti della traiettoria nav dentro BWlumen: %.2f %%\n', insideFrac_nav);
fprintf('Roughness resampled: %.4f | roughness navigata: %.4f\n', ...
        rough_res, rough_nav);
fprintf('Deviazione NAV vs resampled | mean=%.3f voxel | max=%.3f voxel\n', ...
        mean(dev_nav_vs_res), max(dev_nav_vs_res));


%% ------------------------------------------------------------
% STEP 20C - Ricampionamento uniforme della cl_raw per confronto corretto con cl<-resampled--> ricampiono anche cl_raw in 300 punti
%% ------------------------------------------------------------

diffs_raw = diff(cl_raw, 1, 1);
segLen_raw = sqrt(sum(diffs_raw.^2, 2));
arcLen_raw = [0; cumsum(segLen_raw)];

sUniform_raw = linspace(0, arcLen_raw(end), nSamples)';
cl_raw_rs = zeros(nSamples,3);

for k = 1:3
    cl_raw_rs(:,k) = interp1(arcLen_raw, cl_raw(:,k), sUniform_raw, 'pchip');
end

cl_raw_rs(1,:)   = anchor1;
cl_raw_rs(end,:) = anchor2;

D_raw = sampleDistanceOnCurve(D, cl_raw_rs);
Dmin_raw    = min(D_raw);
Dmean_raw   = mean(D_raw);
Dmedian_raw = median(D_raw);

insideMask_raw = pointsInsideMask(cl_raw_rs, BWlumen);
insideFrac_raw = mean(insideMask_raw) * 100;

diffs_raw_mm = diff(cl_raw_rs, 1, 1) .* voxSize;
totalMM_raw  = sum(sqrt(sum(diffs_raw_mm.^2, 2)));

rough_raw = curveRoughness(cl_raw_rs);

dev_raw_vs_res = sqrt(sum((cl_raw_rs - cl_resampled).^2, 2));

fprintf('\n================ CONFRONTO RAW vs RESAMPLED ==================\n');
fprintf('RAW        | L=%.2f mm | Dmin=%.2f | Dmean=%.2f | Dmed=%.2f | inside=%.2f %% | rough=%.4f\n', ...
        totalMM_raw, Dmin_raw, Dmean_raw, Dmedian_raw, insideFrac_raw, rough_raw);
fprintf('RESAMPLED  | L=%.2f mm | Dmin=%.2f | Dmean=%.2f | Dmed=%.2f | inside=%.2f %% | rough=%.4f\n', ...
        totalMM, Dmin, Dmean, Dmedian, insideFrac, rough_res);
fprintf('Deviazione RAW vs RESAMPLED | mean=%.3f voxel | max=%.3f voxel\n', ...
        mean(dev_raw_vs_res), max(dev_raw_vs_res));


%% ------------------------------------------------------------
% STEP 20D - Grafici
%% ------------------------------------------------------------

s_mm_raw = [0; cumsum(sqrt(sum((diff(cl_raw_rs,1,1).*voxSize).^2,2)))];

figure('Name','RAW: D lungo curva + colorazione spaziale','Color','w');
tiledlayout(1,2,'TileSpacing','compact','Padding','compact');

nexttile;
hold on;
plot(s_mm_raw, D_raw, 'm-', 'LineWidth', 1.5);
yline(Dmean_raw, '--', 'Color',[0.85 0.20 0.20], 'LineWidth', 1.2, ...
    'Label', sprintf('media = %.2f', Dmean_raw), ...
    'LabelHorizontalAlignment','right', 'LabelVerticalAlignment','bottom');
yline(Dmedian_raw, ':', 'Color',[0.10 0.10 0.10], 'LineWidth', 1.4, ...
    'Label', sprintf('mediana = %.2f', Dmedian_raw), ...
    'LabelHorizontalAlignment','right', 'LabelVerticalAlignment','top');
[~, idxMinRaw] = min(D_raw);
plot(s_mm_raw(idxMinRaw), D_raw(idxMinRaw), 'ro', 'MarkerFaceColor','r', 'MarkerSize',6);
xlabel('Ascissa lungo la curva [mm]');
ylabel('Distance transform D [voxel]');
title(sprintf('cl\\_raw: D lungo la curva | L = %.1f mm', totalMM_raw));
grid on; box on;
hold off;

nexttile;
ph = patch(isosurface(BWlumen, 0.5));
isonormals(BWlumen, ph);
set(ph, 'FaceColor', [0.8 0.8 1.0], 'EdgeColor', 'none', 'FaceAlpha', 0.08);
hold on;
scatter3(cl_raw_rs(:,2), cl_raw_rs(:,1), cl_raw_rs(:,3), 12, D_raw, 'filled');
plot3(cl_raw_rs(:,2), cl_raw_rs(:,1), cl_raw_rs(:,3), 'k-', 'LineWidth', 0.8);
cb = colorbar;
cb.Label.String = {'Distance transform D', '+D = più centrale', '-D = più vicino alla parete'};
cb.Label.FontSize = 10;
cb.Label.FontWeight = 'bold';
daspect([1 1 1]); view(3); axis tight; axis vis3d;
camlight; lighting gouraud;
title(sprintf('cl\\_raw colorata con D | L = %.1f mm', totalMM_raw));
hold off;


figure('Name','RESAMPLED: D lungo curva + colorazione spaziale','Color','w');
tiledlayout(1,2,'TileSpacing','compact','Padding','compact');

nexttile;
hold on;
plot(s_mm, D_centerline, 'b-', 'LineWidth', 1.5);
yline(Dmean, '--', 'Color',[0.85 0.20 0.20], 'LineWidth', 1.2, ...
    'Label', sprintf('media = %.2f', Dmean), ...
    'LabelHorizontalAlignment','right', 'LabelVerticalAlignment','bottom');
yline(Dmedian, ':', 'Color',[0.10 0.10 0.10], 'LineWidth', 1.4, ...
    'Label', sprintf('mediana = %.2f', Dmedian), ...
    'LabelHorizontalAlignment','right', 'LabelVerticalAlignment','top');
[~, idxMinRes] = min(D_centerline);
plot(s_mm(idxMinRes), D_centerline(idxMinRes), 'ro', 'MarkerFaceColor','r', 'MarkerSize',6);
xlabel('Ascissa lungo la curva [mm]');
ylabel('Distance transform D [voxel]');
title(sprintf('cl\\_resampled: D lungo la curva | L = %.1f mm', totalMM));
grid on; box on;
hold off;

nexttile;
ph = patch(isosurface(BWlumen, 0.5));
isonormals(BWlumen, ph);
set(ph, 'FaceColor', [0.8 0.8 1.0], 'EdgeColor', 'none', 'FaceAlpha', 0.08);
hold on;
scatter3(cl_resampled(:,2), cl_resampled(:,1), cl_resampled(:,3), 12, D_centerline, 'filled');
plot3(cl_resampled(:,2), cl_resampled(:,1), cl_resampled(:,3), 'k-', 'LineWidth', 0.8);
cb = colorbar;
cb.Label.String = {'Distance transform D', '+D = più centrale', '-D = più vicino alla parete'};
cb.Label.FontSize = 10;
cb.Label.FontWeight = 'bold';
daspect([1 1 1]); view(3); axis tight; axis vis3d;
camlight; lighting gouraud;
title(sprintf('cl\\_resampled colorata con D | L = %.1f mm', totalMM));
hold off;


%% ------------------------------------------------------------
% STEP 20E - cl_raw sul colon
%% ------------------------------------------------------------
figure('Name','cl grezza','Color','w');
ph = patch(isosurface(BWlumen, 0.5));
isonormals(BWlumen, ph);
set(ph, 'FaceColor', [0.8 0.8 1.0], 'EdgeColor', 'none', 'FaceAlpha', 0.10);
hold on;

plot3(cl_raw_rs(:,2), cl_raw_rs(:,1), cl_raw_rs(:,3), ...
      '-', 'Color',[0.75 0.00 0.75], 'LineWidth', 1.2, 'DisplayName', 'cl\_raw');

plot3(cl_raw_rs(1,2), cl_raw_rs(1,1), cl_raw_rs(1,3), ...
      'go', 'MarkerSize', 9, 'LineWidth', 2, 'DisplayName', 'Inizio');
plot3(cl_raw_rs(end,2), cl_raw_rs(end,1), cl_raw_rs(end,3), ...
      'bo', 'MarkerSize', 9, 'LineWidth', 2, 'DisplayName', 'Fine');

daspect([1 1 1]); view(3); axis tight; axis vis3d;
camlight; lighting gouraud; legend('Location','best');
title(sprintf('cl\\_raw sul colon | L = %.1f mm', totalMM_raw));
hold off;
%% ------------------------------------------------------------
% STEP 20G - cl_resempled sul colon
%% ------------------------------------------------------------
figure('Name','cl dopo smoothing','Color','w');
ph = patch(isosurface(BWlumen, 0.5));
isonormals(BWlumen, ph);
set(ph, 'FaceColor', [0.8 0.8 1.0], 'EdgeColor', 'none', 'FaceAlpha', 0.10);
hold on;

plot3(cl_resampled(:,2), cl_resampled(:,1), cl_resampled(:,3), ...
      'r-', 'LineWidth', 1.2, 'DisplayName', 'cl\_resampled');

plot3(cl_resampled(1,2), cl_resampled(1,1), cl_resampled(1,3), ...
      'go', 'MarkerSize', 9, 'LineWidth', 2, 'DisplayName', 'Inizio');
plot3(cl_resampled(end,2), cl_resampled(end,1), cl_resampled(end,3), ...
      'bo', 'MarkerSize', 9, 'LineWidth', 2, 'DisplayName', 'Fine');

daspect([1 1 1]); view(3); axis tight; axis vis3d;
camlight; lighting gouraud; legend('Location','best');
title(sprintf('cl\\_resampled sul colon | L = %.1f mm', totalMM));
hold off;

%% ------------------------------------------------------------
% STEP 20H - cl_navigata sul colon
%% ------------------------------------------------------------
figure('Name','cl\_navigata','Color','w');
ph = patch(isosurface(BWlumen, 0.5));
isonormals(BWlumen, ph);
set(ph, 'FaceColor', [0.8 0.8 1.0], 'EdgeColor', 'none', 'FaceAlpha', 0.10);
hold on;

plot3(cl_nav(:,2), cl_nav(:,1), cl_nav(:,3), ...
      'g-', 'LineWidth', 1.2, 'DisplayName', 'cl\_navigata');

plot3(cl_nav(1,2), cl_nav(1,1), cl_nav(1,3), ...
      'go', 'MarkerSize', 9, 'LineWidth', 2, 'DisplayName', 'Inizio');
plot3(cl_nav(end,2), cl_nav(end,1), cl_nav(end,3), ...
      'bo', 'MarkerSize', 9, 'LineWidth', 2, 'DisplayName', 'Fine');

daspect([1 1 1]); view(3); axis tight; axis vis3d;
camlight; lighting gouraud; legend('Location','best');
title(sprintf('cl\\_navigata sul colon | L = %.1f mm', totalMM_nav));
hold off;

%% ------------------------------------------------------------
% STEP 21 - Salvataggio risultati centerline
%% ------------------------------------------------------------

save(outMAT, ...
     'BWshell', 'CAP1', 'CAP2', 'BWclosed', 'BWlumen', 'D', ...
     'adjCap1', 'adjCap2', 'anchor1', 'anchor2', ...
     'cCap1', 'cCap2', 'nCap1', 'nCap2', ...
     'Skel', 'SkelMain', 'centerline_vox', 'cl_raw', ...
     'cl_uniform_first', 'cl_smooth', 'cl_resampled', 'arcLength', 'sUniform', ...
     'D_centerline', 'Dmin', 'Dmean', 'Dmedian', 'insideFrac', ...
     'totalMM', 'voxSize', 'infoShell', ...
     'cl_raw_rs', 'D_raw', 'Dmin_raw', 'Dmean_raw', 'Dmedian_raw', ...
     'insideFrac_raw', 'totalMM_raw', 'rough_raw', ...
     'cl_nav', 'D_nav', 'Dmin_nav', 'Dmean_nav', 'Dmedian_nav', ...
     'insideFrac_nav', 'totalMM_nav', 'nCtrlNav', 'rough_nav', 'rough_res', ...
     'dev_raw_vs_res', 'dev_nav_vs_res');

fprintf('\nSalvato file intermedio: %s\n', outMAT);
fprintf('Parte 1 completata: centerline calcolata e salvata.\n');

%% ============================================================
% FUNZIONI LOCALI
%% ============================================================

function c = getCentroid(BW)
    idx = find(BW);
    if isempty(idx)
        c = [NaN NaN NaN];
        return;
    end
    [x,y,z] = ind2sub(size(BW), idx);
    c = [mean(x) mean(y) mean(z)];
end

function n = getCapNormalPCA(BW)
    idx = find(BW);
    if numel(idx) < 10
        n = [0 0 1];
        return;
    end
    [x,y,z] = ind2sub(size(BW), idx);
    P = [x y z];
    P0 = P - mean(P,1);
    [~,~,V] = svd(P0, 'econ');
    n = V(:,end)';
    n = n / norm(n);
end

function [anchor, regionMask, rayPts] = getAnchorFromCapNormal(CAP, BWlumen, D, centroid, normalVec, name)
    stepSize = 0.5;  %mi muovo lungo la normale di mezzo voxel
    maxStep  = 120;  %Numero massimo di passi lungo una direzione
    searchR  = 6;   %Quando trovo il primo punto dentro il lume, costruisco una regione locale di raggio 6 voxel attorno a quel punto

    dirs = [normalVec; -normalVec]; %provo entrambi i versi della normale per vedere quale è quella giusta per entrare dentro il lume

    found = false;
    bestAnchor = [];
    bestRegion = [];
    bestRay = [];
    bestD = -inf;

    for d = 1:2  %Ciclo sui due versi della normale
        dirVec = dirs(d,:);
        ray = [];

        entered = false;
        entryPoint = [];
%per ogni passo k:
%-Parto dal centroide
%-mi sposto di k*stepSize lungo la direzione dirVec
%---> ottengo P che è un punto continuo
        for k = 0:maxStep
            p = centroid + k * stepSize * dirVec;
            ray = [ray; p]; %#ok<AGROW>
%Trovo il voxel corrispondente a P
            xi = round(p(1));
            yi = round(p(2));
            zi = round(p(3));

            if xi < 1 || yi < 1 || zi < 1 || ...
               xi > size(BWlumen,1) || yi > size(BWlumen,2) || zi > size(BWlumen,3)
                break;
            end
%Se il voxel corrente appartiene al lume:
%-->ho trovato il primo ingresso nel lume
%-->salvo quel punto come entryPoint
            if BWlumen(xi,yi,zi)
                entered = true;
                entryPoint = [xi yi zi];
                break;
            end
        end

        if ~entered
            continue;
        end
%Recupero tutti i voxel del lume
        [lx,ly,lz] = ind2sub(size(BWlumen), find(BWlumen));
        lumenPts = [lx ly lz];
        linLumen = find(BWlumen);
%Qui calcolo, per ogni voxel del lume:
%-la distanza euclidea da entryPoint
%-Poi faccio una soglia: inside = true se il voxel è entro searchR = 6
%ottengo una regione locale nel lume attorno ad entrypoint
        dist = sqrt(sum((lumenPts - entryPoint).^2, 2));
        inside = dist <= searchR;

        if ~any(inside)
            continue;
        end
%Costruisco la maschera della regione locale
        regionMask = false(size(BWlumen));
        regionMask(linLumen(inside)) = true;
        regionMask = keepLargestComponent(regionMask, 26);

        if ~any(regionMask(:))
            continue;
        end
%QUI SCELGO ANCHOR:tra tutti i voxel della regione locale, scelgo quello con valore D massimo--> è il punto più centrale in una piccola regione locale dopo l’ingresso e non semplicemente il primo voxel che incontro dentro il lume
        candidate = argmaxMask(D, regionMask);
        dval = D(candidate(1), candidate(2), candidate(3));

        if dval > bestD
            bestD = dval;
            bestAnchor = candidate;
            bestRegion = regionMask;
            bestRay = ray;
            found = true;
        end
    end

    if ~found
        warning('%s: fallback al voxel del lume più vicino al centroide.', name);
        [lx,ly,lz] = ind2sub(size(BWlumen), find(BWlumen));
        lumenPts = [lx ly lz];
        linLumen = find(BWlumen);

        dist = sqrt(sum((lumenPts - centroid).^2, 2));
        [~, iMin] = min(dist);

        anchor = lumenPts(iMin,:);
        regionMask = false(size(BWlumen));
        regionMask(linLumen(iMin)) = true;
        rayPts = [];
        return;
    end

    anchor = bestAnchor;
    regionMask = bestRegion;
    rayPts = bestRay;

    fprintf('%s: anchor trovato via normale | D=%.2f\n', name, bestD);
end

function BWout = keepLargestComponent(BWin, conn)
    CC = bwconncomp(BWin, conn);
    if CC.NumObjects == 0
        BWout = false(size(BWin));
        return;
    end
    np = cellfun(@numel, CC.PixelIdxList);
    [~, idx] = max(np);
    BWout = false(size(BWin));
    BWout(CC.PixelIdxList{idx}) = true;
end

function p = argmaxMask(D, BWmask)
    idx = find(BWmask);
    if isempty(idx)
        error('Maschera vuota.');
    end
    [~, imax] = max(D(idx));
    [x,y,z] = ind2sub(size(BWmask), idx(imax));
    p = [x y z];
end

function Dvals = sampleDistanceOnCurve(D, curve)
    n = size(curve,1);
    Dvals = zeros(n,1);
    sz = size(D);

    for i = 1:n
        x = round(curve(i,1));
        y = round(curve(i,2));
        z = round(curve(i,3));

        x = min(max(x,1), sz(1));
        y = min(max(y,1), sz(2));
        z = min(max(z,1), sz(3));

        Dvals(i) = D(x,y,z);
    end
end

function insideMask = pointsInsideMask(curve, BW)
    n = size(curve,1);
    insideMask = false(n,1);
    sz = size(BW);

    for i = 1:n
        x = round(curve(i,1));
        y = round(curve(i,2));
        z = round(curve(i,3));

        if x >= 1 && y >= 1 && z >= 1 && ...
           x <= sz(1) && y <= sz(2) && z <= sz(3)
            insideMask(i) = BW(x,y,z);
        end
    end
end

function r = curveRoughness(curve)
    if size(curve,1) < 3
        r = 0;
        return;
    end
    d2 = diff(curve, 2, 1);
    r = mean(sqrt(sum(d2.^2, 2)));
end
