%% ============================================================
%  PARTE 2 - REGISTRAZIONE CENTERLINE SU STL ORIGINALE
%
% INPUT:
%   - OUTPUT_CENTERLINE/centerline_from_caps.mat
%   - INPUT/colon_open.stl
%
% OUTPUT:
%   - OUTPUT_REGISTRATION/centerline_caps_final_registered.mat
%   - OUTPUT_REGISTRATION/colon_registered.stl
%   - OUTPUT_REGISTRATION/centerline_tube_thin.stl

%% ============================================================

clear; clc; close all;

%% ------------------------------------------------------------
% STEP 1 - Nomi file
%% ------------------------------------------------------------


% INPUT
inMAT    = fullfile('OUTPUT_CENTERLINE', 'centerline_from_caps.mat');
fnameSTL = fullfile('INPUT', 'colon_open.stl');

% OUTPUT
outMAT       = fullfile('OUTPUT_REGISTRATION', 'centerline_caps_final_registered.mat');
outColonSTL  = fullfile('OUTPUT_REGISTRATION', 'colon_registered.stl');
outCenterSTL = fullfile('OUTPUT_REGISTRATION', 'centerline_tube_thin.stl');


%% ------------------------------------------------------------
% STEP 2 - Caricamento risultati parte 1
%% ------------------------------------------------------------

if exist(inMAT, 'file') ~= 2
    error('File MAT intermedio non trovato: %s', inMAT);
end

load(inMAT);

fprintf('Caricato file intermedio: %s\n', inMAT);


%% ------------------------------------------------------------
% STEP 3 - Mesh da segmentazione + trasformazione fisica NIfTI
%% ------------------------------------------------------------


fprintf('\n================ REGISTRAZIONE STL ===================\n');

% Estraggo una mesh triangolare dal volume binario BWshell
% La mesh qui è ancora in coordinate voxel
fvSeg = isosurface(BWshell, 0.5);
Fseg_vox = fvSeg.faces;  %facce della mesh segmentata
Vseg_vox = fvSeg.vertices; %vertici della mesh segmentata

%Stampo numero di vertici e triangoli
fprintf('Mesh segmentazione estratta: %d vertici | %d facce\n', ...
        size(Vseg_vox,1), size(Fseg_vox,1));

% Trasformazione voxel -> coordinate fisiche NIfTI
Tnifti = infoShell.Transform.T';

%Applico la trasformazione alla mesh segmentata e alla centerline
Vseg_mm = applyNiftiTransformToIsoVerts(Vseg_vox, Tnifti);
cl_mm   = applyNiftiTransformToCurve(cl_nav, Tnifti);

fprintf('Trasformazione NIfTI applicata a mesh segmentazione e centerline.\n');


%% ------------------------------------------------------------
% STEP 4 - Caricamento STL originale
%% ------------------------------------------------------------

if exist(fnameSTL, 'file') ~= 2
    error('File STL non trovato: %s', fnameSTL);
end

TR = stlread(fnameSTL);
Fstl = TR.ConnectivityList; %Facce del colon STL originale
Vstl = TR.Points;  %Vertici del colon STL originale

fprintf('STL originale: %d vertici | %d facce\n', size(Vstl,1), size(Fstl,1));


%% ------------------------------------------------------------
% STEP 5 - Diagnostica pre-registrazione
%% ------------------------------------------------------------


%Controllo i bounds per confrontare orientamento/posizione
fprintf('\n--- Bounds prima della registrazione ---\n');
printBounds('SEGMENTAZIONE(mm)', Vseg_mm);
printBounds('CENTERLINE(mm)',   cl_mm);
printBounds('STL originale',    Vstl);


%% ------------------------------------------------------------
% STEP 6 - Permutazione/flip fissati + ICP
%
% Visto che la mesh segmentata non è orientata come lo STL originale, eseguo una ricerca automatica su:
%
%   permList = perms(1:3)
%   flipList = tutti gli 8 vettori di segno [+/-1 +/-1 +/-1]
%
% Per ogni combinazione:
%   1) ptsSegTry = ptsSegBase(:,perm)
%   2) ptsSegTry = ptsSegTry .* flipv
%   3) centratura sui centroidi
%   4) ICP contro lo STL
%   5) scelta della configurazione con RMSE minimo
%
% Per il dataset corrente, la configurazione migliore già trovata è:
%   perm = [2 3 1] --> se un punto ero [x y z] , ora diventa [y z x]
%   flip = [-1 1 1] --> asse x cambiato di segno: [x y z] -> [-x y z]
%
% Quindi qui la applico direttamente.
% fprintf('Ricerca automatica permutazioni/flips + ICP...\n');
% 
% nSegSample = min(25000, size(Vseg_mm,1));
% nStlSample = min(25000, size(Vstl,1));
% 
% rng(1);
% idxSeg = randperm(size(Vseg_mm,1), nSegSample);
% idxStl = randperm(size(Vstl,1), nStlSample);
% 
% ptsSegBase = Vseg_mm(idxSeg,:);
% ptsStl     = Vstl(idxStl,:);
% 
% %permutazione degli assi
% permList = perms(1:3);
% %flap dei segni
% flipList = [
%      1  1  1
%      1  1 -1
%      1 -1  1
%      1 -1 -1
%     -1  1  1
%     -1  1 -1
%     -1 -1  1
%     -1 -1 -1
% ];
% 
% bestRMSE = inf;
% bestR_icp = eye(3);
% bestt_icp = zeros(3,1);
% bestPerm = [1 2 3];
% bestFlip = [1 1 1];
% bestPtsSegInit = [];
% 
% %creo una versione candidata della mesh della segmentazione
% 
% for ip = 1:size(permList,1)
%     perm = permList(ip,:);
% 
%     for jf = 1:size(flipList,1)
%         flipv = flipList(jf,:);
% 
%         ptsSegTry = ptsSegBase(:,perm);
%         ptsSegTry = ptsSegTry .* flipv;
% %centratura sui centroidi
%         cSeg = mean(ptsSegTry,1);
%         cStl = mean(ptsStl,1);
% 
%         ptsSeg0 = ptsSegTry - cSeg;
%         ptsStl0 = ptsStl - cStl;
% %ICP
%         pcMoving = pointCloud(ptsSeg0);
%         pcFixed  = pointCloud(ptsStl0);
% 
%         try
%             [tformICP, ~, rmseTry] = pcregistericp(pcMoving, pcFixed, ...
%                 'Metric', 'pointToPlane', ...
%                 'InlierRatio', 0.7, ...
%                 'MaxIterations', 100, ...
%                 'Tolerance', [1e-5 1e-5]);
% 
%             if rmseTry < bestRMSE
%                 bestRMSE = rmseTry;
%                 bestPerm = perm;
%                 bestFlip = flipv;
%                 bestPtsSegInit = ptsSegTry;
% 
%                 if isprop(tformICP, 'R')
%                     bestR_icp = tformICP.R;
%                     bestt_icp = tformICP.Translation(:);
%                 else
%                     bestR_icp = tformICP.T(1:3,1:3);
%                     bestt_icp = tformICP.T(4,1:3)';
%                 end
%             end
% 
%             fprintf('perm=[%d %d %d], flip=[%d %d %d] -> RMSE=%.4f mm\n', ...
%                 perm(1), perm(2), perm(3), ...
%                 flipv(1), flipv(2), flipv(3), rmseTry);
% 
%         catch
%             fprintf('perm=[%d %d %d], flip=[%d %d %d] -> ICP fallito\n', ...
%                 perm(1), perm(2), perm(3), ...
%                 flipv(1), flipv(2), flipv(3));
%         end
%     end
% end
% 
% fprintf('\nMigliore configurazione trovata:\n');
% fprintf('perm = [%d %d %d]\n', bestPerm);
% fprintf('flip = [%d %d %d]\n', bestFlip);
% fprintf('RMSE migliore = %.4f mm\n', bestRMSE);
% 
% Vseg_pf = Vseg_mm(:, bestPerm) .* bestFlip;
% cl_pf   = cl_mm(:,   bestPerm) .* bestFlip;
% 
% cSeg = mean(bestPtsSegInit,1);
% cStl = mean(ptsStl,1);
%% ------------------------------------------------------------

fprintf('\nUso permutazione e flip fissati + ICP...\n');

bestPerm = [2 3 1];
bestFlip = [-1 1 1];

fprintf('Permutazione fissata: [%d %d %d]\n', bestPerm);
fprintf('Flip fissato:         [%d %d %d]\n', bestFlip);

% Applico la stessa trasformazione iniziale sia alla mesh segmentata
% sia alla centerline
Vseg_pf = Vseg_mm(:, bestPerm) .* bestFlip;
cl_pf   = cl_mm(:,   bestPerm) .* bestFlip;

% Campionamento dei punti per ICP: prendi al massimo 25.000 punti da ciascuna mesh.
nSegSample = min(100000, size(Vseg_pf,1));
nStlSample = min(100000, size(Vstl,1));

rng(1);
idxSeg = randperm(size(Vseg_pf,1), nSegSample);
idxStl = randperm(size(Vstl,1), nStlSample);

%Estraggo i punti campionati
ptsSeg = Vseg_pf(idxSeg,:);
ptsStl = Vstl(idxStl,:);

% Centratura sui centroidi prima di ICP
cSeg = mean(ptsSeg,1);  %centroide segmentazione
cStl = mean(ptsStl,1);  %centroide STL

%Traslo ciascun insieme di punti in modo che il suo centroide diventi l’origine
ptsSeg0 = ptsSeg - cSeg;  
ptsStl0 = ptsStl - cStl;  

%Uso oggetti pointCloud per funzioni di registrazione 3D
pcMoving = pointCloud(ptsSeg0); %Nuvola da muovere 
pcFixed  = pointCloud(ptsStl0); %Nuvola di riferiemnto

%ICP finale
%-per ogni punto moving trova il punto più vicino nella fixed
%-stima la trasformazione rigida migliore
%-aggiorna la moving
%-ripete finché converge

%-tformICP: Trasformazione Stimata
%-rmse: errore quadratico medio finale


[tformICP, ~, rmse] = pcregistericp(pcMoving, pcFixed, ...
    'Metric', 'pointToPlane', ...
    'InlierRatio', 0.7, ...
    'MaxIterations', 400, ...
    'Tolerance', [1e-5 1e-5]);


%Estraggo R e t
if isprop(tformICP, 'R')
    R = tformICP.R;
    t_local = tformICP.Translation(:);
else
    R = tformICP.T(1:3,1:3);
    t_local = tformICP.T(4,1:3)';
end

% Ricostruzione della traslazione totale nel frame originale STL
t_total = cStl(:) + t_local - R*cSeg(:);

% Applico la trasformazione finale
Vseg_stl = (R * Vseg_pf' + t_total)';
cl_stl   = (R * cl_pf'   + t_total)';

fprintf('RMSE ICP finale = %.4f mm\n', rmse);


%% ------------------------------------------------------------
% STEP 7 - Diagnostica post-registrazione
%% ------------------------------------------------------------


fprintf('\n--- Bounds dopo la registrazione ---\n');
printBounds('SEGMENTAZIONE registrata', Vseg_stl);
printBounds('CENTERLINE registrata',    cl_stl);
printBounds('STL originale',            Vstl);


%% ------------------------------------------------------------
% STEP 8 - Visualizzazione overlay delle due mesh
%
% Mostro:
%   - STL originale
%   - mesh della segmentazione registrata
%% ------------------------------------------------------------

figure('Name','Overlay mesh: STL originale + segmentazione registrata');

trisurf(Fstl, Vstl(:,1), Vstl(:,2), Vstl(:,3), ...
        'FaceColor', [0.85 0.85 0.90], ...
        'EdgeColor', 'none', ...
        'FaceAlpha', 0.20);
hold on;

trisurf(Fseg_vox, Vseg_stl(:,1), Vseg_stl(:,2), Vseg_stl(:,3), ...
        'FaceColor', [1.0 0.4 0.4], ...
        'EdgeColor', 'none', ...
        'FaceAlpha', 0.18);

axis equal;
view(3);
axis tight;
axis vis3d;
camlight;
lighting gouraud;

title(sprintf('Overlay mesh | STL originale + segmentazione registrata | RMSE = %.3f mm', rmse));
hold off;

%% ------------------------------------------------------------
% STEP 9 - Visualizzazione finale STL + centerline registrata
%% ------------------------------------------------------------

figure('Name','STL + Centerline registrata finale');

trisurf(Fstl, Vstl(:,1), Vstl(:,2), Vstl(:,3), ...
        'FaceColor', [0.85 0.85 0.90], ...
        'EdgeColor', 'none', ...
        'FaceAlpha', 0.20);
hold on;

plot3(cl_stl(:,1), cl_stl(:,2), cl_stl(:,3), 'r-', 'LineWidth', 3);
plot3(cl_stl(1,1),   cl_stl(1,2),   cl_stl(1,3), ...
      'go', 'MarkerSize', 14, 'LineWidth', 3);
plot3(cl_stl(end,1), cl_stl(end,2), cl_stl(end,3), ...
      'bo', 'MarkerSize', 14, 'LineWidth', 3);

axis equal; view(3); axis tight; axis vis3d;
camlight; lighting gouraud;
title(sprintf('STL + Centerline registrata | RMSE ICP = %.3f mm', rmse));
hold off;

%% ------------------------------------------------------------
% STEP 10 - Costruzione tubo centerline sottile per ottenere una superficie
%% ------------------------------------------------------------

tubeRadius = 0.5;   % mm
nCircle    = 16;

[Ftube, Vtube] = buildTubeMesh(cl_stl, tubeRadius, nCircle);


%% ------------------------------------------------------------
% STEP 11 - Esportazione STL separati
%% ------------------------------------------------------------


TRcolon = triangulation(Fstl, Vstl);
stlwrite(TRcolon, outColonSTL);
fprintf('Salvato: %s\n', outColonSTL);

TRtube = triangulation(Ftube, Vtube);
stlwrite(TRtube, outCenterSTL);
fprintf('Salvato: %s\n', outCenterSTL);

%% ------------------------------------------------------------
% STEP 12 - Salvataggio MAT finale
%% ------------------------------------------------------------

save(outMAT, ...
     'BWshell', 'CAP1', 'CAP2', 'BWclosed', 'BWlumen', 'D', ...
     'adjCap1', 'adjCap2', 'anchor1', 'anchor2', ...
     'cCap1', 'cCap2', 'nCap1', 'nCap2', ...
     'Skel', 'SkelMain', 'centerline_vox', 'cl_raw', ...
     'cl_smooth', 'cl_resampled', 'arcLength', 'sUniform', ...
     'D_centerline', 'Dmin', 'Dmean', 'Dmedian', 'insideFrac', ...
     'totalMM', 'voxSize', 'infoShell', ...
     'Fseg_vox', 'Vseg_vox', 'Vseg_mm', ...
     'Fstl', 'Vstl', ...
     'Tnifti', 'R', 't_total', 'rmse', ...
     'bestPerm', 'bestFlip', ...
     'cl_mm', 'cl_stl', 'Vseg_stl', ...
     'Ftube', 'Vtube', 'tubeRadius');

fprintf('\nSalvato: %s\n', outMAT);
fprintf('Parte 2 completata.\n');

%% ============================================================
% FUNZIONI LOCALI NECESSARIE ALLA PARTE 2
%% ============================================================

function Vmm = applyNiftiTransformToIsoVerts(Vvox, T)
    n = size(Vvox,1);
    Vmm = zeros(n,3);

    for i = 1:n
        p = [Vvox(i,1); Vvox(i,2); Vvox(i,3); 1];
        q = T * p;
        Vmm(i,:) = q(1:3)';
    end
end

function Cmm = applyNiftiTransformToCurve(Cvox, T)
    n = size(Cvox,1);
    Cmm = zeros(n,3);

    for i = 1:n
        p = [Cvox(i,2); Cvox(i,1); Cvox(i,3); 1];
        q = T * p;
        Cmm(i,:) = q(1:3)';
    end
end

function printBounds(nameStr, V)
    fprintf('%s bounds:\n', nameStr);
    fprintf('  X=[%.2f %.2f]\n', min(V(:,1)), max(V(:,1)));
    fprintf('  Y=[%.2f %.2f]\n', min(V(:,2)), max(V(:,2)));
    fprintf('  Z=[%.2f %.2f]\n', min(V(:,3)), max(V(:,3)));
end

function [F, V] = buildTubeMesh(C, radius, nCircle)
    nPts = size(C,1);

    if nPts < 2
        error('Centerline troppo corta per costruire un tubo.');
    end

    T = zeros(nPts,3);
    for i = 2:nPts-1
        v = C(i+1,:) - C(i-1,:);
        T(i,:) = v / norm(v);
    end
    T(1,:)   = C(2,:) - C(1,:);
    T(end,:) = C(end,:) - C(end-1,:);
    T(1,:)   = T(1,:) / norm(T(1,:));
    T(end,:) = T(end,:) / norm(T(end,:));

    ref = [0 0 1];
    if abs(dot(ref, T(1,:))) > 0.9
        ref = [0 1 0];
    end

    N = cross(T(1,:), ref);
    N = N / norm(N);
    B = cross(T(1,:), N);
    B = B / norm(B);

    Nall = zeros(nPts,3);
    Ball = zeros(nPts,3);
    Nall(1,:) = N;
    Ball(1,:) = B;

    for i = 2:nPts
        ti = T(i,:);
        ni = Nall(i-1,:) - dot(Nall(i-1,:), ti) * ti;

        if norm(ni) < 1e-8
            ref = [1 0 0];
            if abs(dot(ref, ti)) > 0.9
                ref = [0 1 0];
            end
            ni = cross(ti, ref);
        end

        ni = ni / norm(ni);
        bi = cross(ti, ni);
        bi = bi / norm(bi);

        Nall(i,:) = ni;
        Ball(i,:) = bi;
    end

    theta = linspace(0, 2*pi, nCircle+1);
    theta(end) = [];

    V = zeros(nPts*nCircle, 3);

    for i = 1:nPts
        for k = 1:nCircle
            idx = (i-1)*nCircle + k;
            dir = cos(theta(k))*Nall(i,:) + sin(theta(k))*Ball(i,:);
            V(idx,:) = C(i,:) + radius * dir;
        end
    end

    F = [];
    for i = 1:nPts-1
        base1 = (i-1)*nCircle;
        base2 = i*nCircle;

        for k = 1:nCircle
            k2 = mod(k, nCircle) + 1;

            v1 = base1 + k;
            v2 = base1 + k2;
            v3 = base2 + k;
            v4 = base2 + k2;

            F(end+1,:) = [v1 v3 v2]; %#ok<AGROW>
            F(end+1,:) = [v2 v3 v4]; %#ok<AGROW>
        end
    end

    cStart = size(V,1) + 1;
    cEnd   = size(V,1) + 2;

    V = [V; C(1,:); C(end,:)];

    base1 = 0;
    for k = 1:nCircle
        k2 = mod(k, nCircle) + 1;
        F(end+1,:) = [cStart base1+k2 base1+k]; %#ok<AGROW>
    end

    baseN = (nPts-1)*nCircle;
    for k = 1:nCircle
        k2 = mod(k, nCircle) + 1;
        F(end+1,:) = [cEnd baseN+k baseN+k2]; %#ok<AGROW>
    end
end
