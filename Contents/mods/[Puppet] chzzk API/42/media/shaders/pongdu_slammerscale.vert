#version 330

// PongDu slammer: basicEffect copy that scales only the upper body (Bip01_Spine1 and its children).
// Pivot is the posed Spine1 joint, so it follows the animation (also for corpses lying down).
// Per vertex the scale is blended by the weight on upper bones; the waist band stays at 1.0
// so it matches vanilla jeans and legs. Used by m_Shader on slammer clothing items only.
// Bone indices follow the Human skeleton (Skinned/MaleBody.x frame order): 4=Spine1 .. 19=BackPack.
const float PONGDU_SCALE = 1.1;
const int PONGDU_SPINE1 = 4;
const int PONGDU_UPPER_FIRST = 4;
const int PONGDU_UPPER_LAST = 19;
const vec4 PONGDU_SPINE1_BIND = vec4(0.0, 0.663, 0.0174, 1.0); // bind position from MaleBody.x offset matrix
const float PONGDU_BLEND_LO = 0.3;  // upper weight at the waist band (stays 1.0 below this)
const float PONGDU_BLEND_HI = 0.9;  // upper weight where the full scale is reached

float pongduUpperWeight(vec4 w, vec4 idx)
{
	float f = 0.0;
	if (int(idx.x) >= PONGDU_UPPER_FIRST && int(idx.x) <= PONGDU_UPPER_LAST) f += w.x;
	if (int(idx.y) >= PONGDU_UPPER_FIRST && int(idx.y) <= PONGDU_UPPER_LAST) f += w.y;
	if (int(idx.z) >= PONGDU_UPPER_FIRST && int(idx.z) <= PONGDU_UPPER_LAST) f += w.z;
	if (int(idx.w) >= PONGDU_UPPER_FIRST && int(idx.w) <= PONGDU_UPPER_LAST) f += w.w;
	return smoothstep(PONGDU_BLEND_LO, PONGDU_BLEND_HI, f);
}

layout (location = 0) in vec4 vertex;
layout (location = 1) in vec4 normal;
layout (location = 2) in vec4 boneWeights;
layout (location = 3) in vec4 boneIndices;
layout (location = 4) in vec2 uv;

out vec3 vertColour;
out vec3 vertNormal;
out vec2 texCoords;

uniform mat4 ModelViewProjection;
uniform float targetDepth = 0.5;
uniform float DepthBias;
uniform mat4 MatrixPalette[60];
uniform vec2 UVScale = vec2(1,1);
uniform float HighResDepthMultiplier = 0.0; // 0.5 when drawing models to double-sized chunk textures
uniform float FinalScale = 1.0;

void main()
{
	vec4 position = vec4(vertex.xyz, 1.0);
	vec4 normal = vec4(normal.xyz, 0.0);

	texCoords = uv * UVScale.xy;

	mat4 boneEffect = mat4(0.0);
	if(boneWeights.x > 0.0)
		boneEffect += MatrixPalette[int(boneIndices.x)] * boneWeights.x;
	if(boneWeights.y > 0.0)
		boneEffect += MatrixPalette[int(boneIndices.y)] * boneWeights.y;
	if(boneWeights.z > 0.0)
		boneEffect += MatrixPalette[int(boneIndices.z)] * boneWeights.z;
	if(boneWeights.w > 0.0)
		boneEffect += MatrixPalette[int(boneIndices.w)] * boneWeights.w;

	normal = boneEffect * normal;
	vertNormal = normal.xyz;

#if 1
	vertColour = vec3(1.0);
#else
	vec3 scalevec;
	mat4 m = boneEffect;

    scalevec.x = length(vec3(m[0][0], m[0][1], m[0][2]));
    scalevec.y = length(vec3(m[1][0], m[1][1], m[1][2]));
    scalevec.z = length(vec3(m[2][0], m[2][1], m[2][2]));
    float scale = length(scalevec);
	float blood = scale;
	blood = clamp(blood, 0.0, 0.01)  * 100.0;
	vertColour = vec3(1.0,blood,blood);


#endif

	vec4 positionScaled = boneEffect * position;
	vec3 pongduPivot = (MatrixPalette[PONGDU_SPINE1] * PONGDU_SPINE1_BIND).xyz;
	float pongduK = 1.0 + (PONGDU_SCALE - 1.0) * pongduUpperWeight(boneWeights, boneIndices);
	positionScaled.xyz = pongduPivot + (positionScaled.xyz - pongduPivot) * pongduK;
	positionScaled.xyz *= FinalScale;
	vec4 o = ModelViewProjection * positionScaled;

	vec4 origin = ModelViewProjection * vec4(0, 0, 0, 1);
	o.z += (origin.z - o.z) * HighResDepthMultiplier;

//	o.z -= DepthBias;
//	o.z /= 16.0f;
	float clip = ((o.z+1.0) / 2.0); // -1,+1 -> 0,2 -> 0,1
	clip += targetDepth - 0.5;
	o.z = (clip*2)-1; // 0-1 -> 0-2 -> -1,+1

	gl_Position = o;
}
