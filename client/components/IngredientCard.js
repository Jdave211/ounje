import {
  View,
  Text,
  ScrollView,
  Image,
  StyleSheet,
  TouchableHighlight,
} from "react-native";
import { entitle } from "../utils/helpers";
import { FontAwesome, Feather, MaterialIcons } from "@expo/vector-icons";

const IngredientCard = ({
  name,
  image,
  amount,
  unit,
  onCancel,
  showCancelButton = false,
}) => {
  return (
    <View style={styles.ingredient}>
      {showCancelButton && (
        <TouchableHighlight
          style={{
            backgroundColor: "rgb(180, 180, 180)",
            borderRadius: 100,
            zIndex: 1,
            position: "absolute",
            right: -5,
            top: -5,
          }}
          onPress={() => this.submitSuggestion(this.props)}
          underlayColor="#fff"
        >
          <MaterialIcons
            name="cancel"
            size={18}
            color="black"
            style={{}}
            onPress={onCancel}
          />
        </TouchableHighlight>
      )}
      <View>
        <Image
          style={styles.ingredientImage}
          source={{
            uri: image,
          }}
        />
      </View>
      <Text style={styles.ingredientText}>{entitle(name)}</Text>
      {amount && (
        <Text style={styles.ingredientAmount}>
          {amount} {unit}
        </Text>
      )}
    </View>
  );
};

const styles = StyleSheet.create({
  ingredient: {
    flex: 1,
    // display: "flex",
    flexDirection: "column",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: "auto",
    padding: 5,
    width: 90,
    height: 100,
    backgroundColor: "rgba(0, 0, 0, 0.2)",
  },
  ingredientImage: {
    width: 40,
    height: 40,
    // borderRadius: 10,
    // marginRight: 10,
  },
  ingredientTextContainer: {
    flex: 1,
    flexDirection: "column",
    // alignItems: "flex-start",
  },
  ingredientText: {
    fontSize: 13,
    color: "white",
  },
  ingredientAmount: {
    fontSize: 13,
    color: "gray",
  },
  fullInstructions: {
    marginTop: 5,
    marginBottom: 45,
  },
  instruction: {
    flexDirection: "row",
    alignItems: "flex-start",
    paddingVertical: 8,
    marginBottom: 7,
    paddingRight: 20,
  },
});

export default IngredientCard;
