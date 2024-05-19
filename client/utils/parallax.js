import { Extrapolate, interpolate } from "react-native-reanimated";
const isValidSize = (size) => {
  "worklet";
  return size && size.width > 0 && size.height > 0;
};

const defaultAnchorPoint = { x: 0.5, y: 0.5 };

export const withAnchorPoint = (transform, anchorPoint, size) => {
  "worklet";

  if (!isValidSize(size)) return transform;

  let injectedTransform = transform.transform;
  if (!injectedTransform) return transform;

  if (anchorPoint.x !== defaultAnchorPoint.x && size.width) {
    const shiftTranslateX = [];

    // shift before rotation
    shiftTranslateX.push({
      translateX: size.width * (anchorPoint.x - defaultAnchorPoint.x),
    });
    injectedTransform = [...shiftTranslateX, ...injectedTransform];
    // shift after rotation
    injectedTransform.push({
      translateX: size.width * (defaultAnchorPoint.x - anchorPoint.x),
    });
  }

  if (!Array.isArray(injectedTransform))
    return { transform: injectedTransform };

  if (anchorPoint.y !== defaultAnchorPoint.y && size.height) {
    const shiftTranslateY = [];
    // shift before rotation
    shiftTranslateY.push({
      translateY: size.height * (anchorPoint.y - defaultAnchorPoint.y),
    });
    injectedTransform = [...shiftTranslateY, ...injectedTransform];
    // shift after rotation
    injectedTransform.push({
      translateY: size.height * (defaultAnchorPoint.y - anchorPoint.y),
    });
  }

  return { transform: injectedTransform };
};

export function parallaxLayout(baseConfig) {
  const { size } = baseConfig;
  // const {
  //   parallaxScrollingOffset = 100,
  //   parallaxScrollingScale = 0.8,
  //   parallaxAdjacentItemScale = parallaxScrollingScale ** 2,
  // } = modeConfig;

  const parallaxScrollingScale = 1;
  const parallaxAdjacentItemScale = 0.8;
  const parallaxScrollingOffset = -40;

  return (value) => {
    "worklet";
    const translateY = interpolate(
      value,
      [-1, 0, 1],
      [-size + parallaxScrollingOffset, 0, size - parallaxScrollingOffset],
    );

    const translateX = interpolate(
      value,
      [-1, 0, 1, 2],
      [-size * 0.2, 0, 0, -size * 0.2],
    );

    const zIndex = interpolate(
      value,
      [-1, 0, 1, 2],
      [0, size, size, 0],
      Extrapolate.CLAMP,
    );

    const scale = interpolate(
      value,
      [-1, 0, 1, 2],
      [
        parallaxAdjacentItemScale,
        parallaxScrollingScale,
        parallaxScrollingScale,
        parallaxAdjacentItemScale,
      ],
      Extrapolate.CLAMP,
    );

    const rotateY = interpolate(
      value,
      [-1, 0, 1, 2],
      [20, 0, 0, 20],
      Extrapolate.CLAMP,
    );

    const rotateZ = interpolate(
      value,
      [-1, 0, 1, 2],
      [-20, 0, 0, -20],
      Extrapolate.CLAMP,
    );

    const transform = {
      transform: [
        { translateY: translateX },
        { translateX: translateY },
        { perspective: 200 },
        {
          rotateY: `${rotateY}deg`,
        },
        {
          rotateZ: `${rotateZ}deg`,
        },
        { scale },
      ],
    };

    return {
      ...withAnchorPoint(
        transform,
        { x: 0.5, y: 0.5 },
        { width: size, height: size },
      ),
      zIndex,
    };
  };
}
