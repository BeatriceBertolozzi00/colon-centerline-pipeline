# Colon Centerline Reconstruction and Registration Pipeline

## Overview

This repository contains a MATLAB pipeline, divided into two main parts, designed to:

- Reconstruct the internal colon lumen from volumetric segmentations.
- Extract a geometrically centered colon centerline.
- Regularize the resulting trajectory for simulation and navigation purposes.
- Register the final trajectory to the original colon STL model.

The workflow combines:

- **3D Slicer** for preprocessing and volumetric input generation.
- **MATLAB** for lumen reconstruction, centerline extraction, validation, and final registration to the original STL model.

---

## 3D Slicer

Three main preprocessing steps were performed in 3D Slicer.

### 1. Volumetric Representation of the Colon

The original surface mesh was converted into a voxel-based segmentation of the colon.

### 2. Construction of a Closed Colon Shell

A closed representation of the colon wall was created to distinguish between:

- Exterior region
- Colon wall
- Internal lumen

This step was necessary to enable the reconstruction of the internal lumen in MATLAB.

### 3. Creation of Two Separate Caps

Two separate caps were created:

- `CAP_1`
- `CAP_2`

These caps serve as geometric markers identifying the two openings of the colon.

They provide the boundary conditions for centerline extraction:

- The centerline must start at one colon opening.
- The centerline must terminate at the opposite opening.

### Outputs Exported from 3D Slicer

Three volumetric datasets were exported:

- Voxelized colon shell
- First opening cap
- Second opening cap

---

## MATLAB

The MATLAB pipeline consists of two main parts.

### Part 1 — Centerline Reconstruction

**Script:** `compute_centerline_part1.m`

#### Inputs

- `Segmentation_colon-colonShell_2-label.nii`
- `Segmentation_colon-Cap_1-label.nii`
- `Segmentation_colon-Cap_2-label_1.nii`

#### Processing Steps

1. Load the NIfTI volumes exported from 3D Slicer.
2. Construct a closed colon shell by combining the shell and the two caps.
3. Reconstruct the internal lumen using an exterior flood-fill approach.
4. Compute the distance transform of the lumen.
5. Estimate the centroid and surface normal of each cap.
6. Identify two internal lumen anchors based on the cap geometry.
7. Extract the lumen skeleton.
8. Select the main connected component of the skeleton.
9. Construct a weighted graph from the skeleton voxels.
10. Compute the shortest path between the two endpoints.
11. Extract the raw centerline from the resulting path.
12. Apply smoothing and uniform resampling.
13. Generate an additional regularized trajectory for navigation purposes.
14. Perform quantitative validation of the resulting trajectories.

#### Main Output

- `centerline_from_caps.mat`

### Generated Centerline Representations

Three different centerline representations are computed:

- **`cl_raw`**: Raw centerline extracted from the shortest path along the skeleton.
- **`cl_resampled`**: Smoothed and uniformly resampled centerline.
- **`cl_nav`**: Final regularized trajectory intended for navigation and simulation.

---

### Part 2 — Centerline Registration to the Original STL

**Script:** `register_centerline_to_stl_part2.m`

#### Inputs

- `centerline_from_caps.mat`
- `colon_open.stl`

#### Processing Steps

1. Load the centerline reconstruction results from Part 1.
2. Extract a triangular surface mesh from the colon segmentation.
3. Transform both the mesh and the centerline from voxel coordinates to the physical NIfTI coordinate system.
4. Load the original colon STL model.
5. Apply the axis permutation and sign flips previously identified as optimal for the dataset.
6. Refine the alignment using the Iterative Closest Point (ICP) algorithm.
7. Apply the final transformation to both the segmented mesh and the centerline.
8. Visualize the overlay between the registered mesh and the original STL model.
9. Visualize the registered centerline within the original colon STL.
10. Generate a thin tubular mesh around the final centerline.
11. Export the resulting STL files.

#### Main Outputs

- `centerline_caps_final_registered.mat`
- `colon_registered.stl`
- `centerline_tube_thin.stl`

---

## Additional Notes

### 1. Axis Permutation and Flip Optimization

An initial automatic search was performed to identify the optimal coordinate transformation between the segmented colon mesh and the original STL model.

The search considered:

- All 6 possible axis permutations.
- All 8 possible combinations of axis sign flips.

This resulted in **48 candidate initial configurations**.

For each configuration:

1. The corresponding axis permutation and sign flips were applied to the segmented mesh.
2. The transformed mesh and the reference STL were centered using their respective centroids.
3. ICP registration was performed against the original STL model.
4. The final Root Mean Square Error (RMSE) was evaluated and compared.

The best-performing configuration was:

- `perm = [2 3 1]`
- `flip = [-1 1 1]`

This configuration was subsequently fixed in the final registration script.

### 2. Current Limitations and Future Improvements

The three input volumes generated in 3D Slicer still require further refinement, **particularly the two cap segmentations (`CAP_1` and `CAP_2`)**.

Improving the quality and geometric accuracy of these inputs is an important next step toward obtaining a more reliable centerline reconstruction.

---

## Visualization Results

The `docs/images` directory contains the graphical results of the pipeline, saved as MATLAB `.fig` files for interactive 3D visualization.

### 1. Anchor Diagnostics

Visualization of the two caps, their estimated centroids and associated normal vectors, and the selected internal anchors used to define the centerline endpoints.

![Anchor diagnostics](https://github.com/user-attachments/assets/b2d741cd-2a58-457b-868f-7062cff0e298)

### 2. Distance Transform Along `cl_raw`

The plot shows the distance transform values (D) evaluated along the raw centerline (`cl_raw`).

The corresponding 3D visualization displays the raw centerline colored according to its distance from the lumen boundary.

Higher D values indicate points located farther from the colon wall and therefore generally closer to the central region of the lumen.

![Raw centerline distance transform plot](https://github.com/user-attachments/assets/c19ed3c9-9f43-479c-9431-084ebbdcf9bc)

![Raw centerline distance transform 3D visualization](https://github.com/user-attachments/assets/59a11e4f-576a-4f70-bd06-77870a6af6b8)

### 3. Distance Transform Along `cl_resampled`

Distance transform analysis of the smoothed and uniformly resampled centerline (`cl_resampled`).

![Resampled centerline distance transform plot](https://github.com/user-attachments/assets/2c6032af-5902-4d42-8ff8-f50a39fc7103)

![Resampled centerline distance transform 3D visualization](https://github.com/user-attachments/assets/2969b9a5-cf16-485b-aa8d-316da9d6452a)

### 4. Distance Transform Along `cl_nav`

Distance transform analysis of the final regularized navigation trajectory (`cl_nav`).

![Navigation centerline distance transform plot](https://github.com/user-attachments/assets/9289b18a-8cd4-4755-bdbb-90440d7e5058)

![Navigation centerline distance transform 3D visualization](https://github.com/user-attachments/assets/ba2f0925-c921-4aff-b95c-a2575a995997)

### 5. Raw Centerline and Colon Model

3D visualization of the raw centerline (`cl_raw`) within the reconstructed colon geometry.

![Raw centerline and colon](https://github.com/user-attachments/assets/f8fd410c-defa-4fb0-99cb-f2baaf803934)

### 6. Resampled Centerline and Colon Model

3D visualization of the smoothed and uniformly resampled centerline (`cl_resampled`) within the reconstructed colon geometry.

![Resampled centerline and colon](https://github.com/user-attachments/assets/52f3c762-9af2-4864-b965-88f52b4742f5)

### 7. Navigation Centerline and Colon Model

3D visualization of the final regularized navigation trajectory (`cl_nav`) within the reconstructed colon geometry.

![Navigation centerline and colon](https://github.com/user-attachments/assets/67c3236d-ad66-48af-90f3-6a53ef750fac)

### 8. Mesh Registration Overlay

Visual comparison between the original colon STL model and the registered segmented mesh.

The final alignment is quantitatively evaluated using the ICP RMSE.

![Mesh registration overlay](https://github.com/user-attachments/assets/f87989d7-0d6a-45cf-ba2b-f4fe407b1124)

### 9. Registered Centerline and Original STL Model

Final visualization of the registered centerline (`cl_stl`) aligned with the original colon STL model.

The resulting trajectory is transformed into the reference STL coordinate system using the registration transformation obtained through ICP.

![Registered centerline and original STL](https://github.com/user-attachments/assets/876c48ba-e2fa-42c1-a362-392b4a2c63ec)




