import React, { useState } from "react";
import {
  View,
  Text,
  TouchableOpacity,
  StyleSheet,
  ScrollView,
  Alert,
} from "react-native";
import { MaterialIcons } from "@expo/vector-icons";

const plansData = {
  monthly: [
    {
      id: "1",
      name: "Basic",
      price: "Free",
      features: [
        "Up to 15 Inventory Items",
        "3 Recipes per Week",
        "Basic Customization",
        "1 Fridge Image",
      ],
    },
    {
      id: "2",
      name: "Premium",
      price: "$5.99",
      features: [
        "Unlimited Inventory Items",
        "Unlimited Recipes",
        "Advanced Customization",
        "Calorie Tracking",
        "Beta Features Access",
      ],
      billed: "Billed Monthly",
    },
  ],
  annually: [
    {
      id: "1",
      name: "Basic",
      price: "Free",
      features: [
        "Up to 15 Inventory Items",
        "3 Recipes per Week",
        "Basic Customization",
        "1 Fridge Image",
      ],
    },
    {
      id: "2",
      name: "Premium",
      price: "$59.99",
      features: [
        "Unlimited Inventory Items",
        "Unlimited Recipes",
        "Advanced Customization",
        "Calorie Tracking",
        "Beta Features Access",
      ],
      billed: "Billed Yearly",
    },
  ],
  lifetime: [
    {
      id: "1",
      name: "Basic",
      price: "Free",
      features: [
        "Up to 15 Inventory Items",
        "3 Recipes per Week",
        "Basic Customization",
        "1 Fridge Image",
      ],
    },
    {
      id: "2",
      name: "Premium",
      price: "$49.99",
      features: [
        "Unlimited Inventory Items",
        "Unlimited Recipes",
        "Advanced Customization",
        "Calorie Tracking",
        "Beta Features Access",
      ],
      billed: "Pay once - Lifetime Access",
    },
  ],
};

export default function PremiumSubscription({ navigation }) {
  const [subscriptionPeriod, setSubscriptionPeriod] = useState("monthly");
  const [selectedPlan, setSelectedPlan] = useState(
    plansData[subscriptionPeriod][1]
  );
  const plans = plansData[subscriptionPeriod];

  const handlePlanSelect = (plan) => {
    setSelectedPlan(plan);
  };

  const isPremiumPlan = selectedPlan.name === "Premium";

  return (
    <View style={styles.container}>
      {/* Back Button */}
      <TouchableOpacity
        onPress={() => navigation.goBack()}
        style={styles.backButton}
      >
        <MaterialIcons name="arrow-back-ios" size={24} color="#fff" />
      </TouchableOpacity>

      {/* Header */}
      <Text style={styles.header}>Upgrade to Premium</Text>

      {/* Subscription Period Toggle */}
      <View style={styles.toggleContainer}>
        {["monthly", "annually", "lifetime"].map((period) => (
          <TouchableOpacity
            key={period}
            style={[
              styles.toggleButton,
              subscriptionPeriod === period && styles.selectedToggle,
            ]}
            onPress={() => {
              setSubscriptionPeriod(period);
              setSelectedPlan(plansData[period][1]);
            }}
          >
            <Text
              style={[
                styles.toggleText,
                subscriptionPeriod === period && styles.selectedToggleText,
              ]}
            >
              {period.charAt(0).toUpperCase() + period.slice(1)}
            </Text>
          </TouchableOpacity>
        ))}
      </View>

      {/* Plans */}
      <ScrollView contentContainerStyle={styles.scrollContainer}>
        {plans.map((plan) => (
          <TouchableOpacity
            key={plan.id}
            style={[
              styles.planCard,
              selectedPlan.id === plan.id && styles.selectedPlanCard,
            ]}
            onPress={() => handlePlanSelect(plan)}
          >
            <View style={styles.planHeader}>
              <Text style={styles.planName}>{plan.name}</Text>
              <Text style={styles.planPrice}>{plan.price}</Text>
            </View>
            <View style={styles.featuresList}>
              {plan.features.map((feature, index) => (
                <View style={styles.featureItem} key={index}>
                  <MaterialIcons name="check" size={20} color="silver" />
                  <Text style={styles.featureText}>{feature}</Text>
                </View>
              ))}
            </View>
            {plan.billed && (
              <Text style={styles.planBilled}>{plan.billed}</Text>
            )}
          </TouchableOpacity>
        ))}
      </ScrollView>

      {/* Subscribe Button */}
      {isPremiumPlan && (
        <TouchableOpacity
          style={styles.subscribeButton}
          onPress={() =>
            Alert.alert(
              "Coming Soon",
              "Premium subscriptions will be available soon!"
            )
          }
        >
          <Text style={styles.subscribeButtonText}>Subscribe Now</Text>
        </TouchableOpacity>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: "#121212",
    paddingTop: 50,
  },
  backButton: {
    position: "absolute",
    top: 50,
    left: 20,
    zIndex: 1,
  },
  header: {
    fontSize: 28,
    fontWeight: "bold",
    color: "#FFFFFF",
    textAlign: "center",
    marginBottom: 20,
  },
  toggleContainer: {
    flexDirection: "row",
    alignSelf: "center",
    backgroundColor: "#1e1e1e",
    borderRadius: 8,
    overflow: "hidden",
    marginBottom: 20,
  },
  toggleButton: {
    paddingVertical: 10,
    paddingHorizontal: 20,
  },
  selectedToggle: {
    backgroundColor: "#2E2E2E",
  },
  toggleText: {
    color: "#FFFFFF",
    fontSize: 16,
  },
  selectedToggleText: {
    color: "#FFFFFF",
    fontWeight: "bold",
  },
  scrollContainer: {
    paddingHorizontal: 20,
    paddingBottom: 100,
  },
  planCard: {
    backgroundColor: "#1e1e1e",
    borderRadius: 12,
    padding: 20,
    marginBottom: 20,
  },
  selectedPlanCard: {
    borderWidth: 2,
    borderColor: "#1B4D3E", // Subtle green border
  },
  planHeader: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    marginBottom: 10,
  },
  planName: {
    fontSize: 22,
    fontWeight: "bold",
    color: "#FFFFFF",
  },
  planPrice: {
    fontSize: 22,
    fontWeight: "bold",
    color: "#FFFFFF",
  },
  planBilled: {
    fontSize: 14,
    color: "gray",
    marginTop: 10,
    textAlign: "center",
  },
  featuresList: {
    marginTop: 10,
  },
  featureItem: {
    flexDirection: "row",
    alignItems: "center",
    marginBottom: 8,
  },
  featureText: {
    color: "#FFFFFF",
    marginLeft: 10,
    fontSize: 15,
  },
  subscribeButton: {
    position: "absolute",
    bottom: 30,
    left: 20,
    right: 20,
    backgroundColor: "#2E2E2E",
    borderRadius: 8,
    padding: 15,
    alignItems: "center",
  },
  subscribeButtonText: {
    color: "#FFFFFF",
    fontSize: 18,
    fontWeight: "bold",
  },
});
