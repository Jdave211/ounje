import React, { useState } from "react";
import {
  View,
  Text,
  TouchableOpacity,
  StyleSheet,
  ScrollView,
} from "react-native";
import { Icon } from "react-native-elements";

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
      billed: "monthly",
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
      billed: "save $12",
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
      billed: "limited time offer",
    },
  ],
};

export default function PremiumSubscription({ navigation }) {
  const [subscriptionPeriod, setSubscriptionPeriod] = useState("monthly");
  const [selectedPlan, setSelectedPlan] = useState(
    plansData[subscriptionPeriod][1],
  );
  const plans = plansData[subscriptionPeriod];

  const handlePlanSelect = (plan) => {
    setSelectedPlan(plan);
  };

  const isPremiumPlan = selectedPlan.name === "Premium";

  return (
    <View style={styles.container}>
      <TouchableOpacity
        onPress={() => navigation.goBack()}
        style={styles.backButton}
      >
        <Icon name="arrow-back" type="material" color="gray" />
      </TouchableOpacity>
      <Text style={styles.header}>Subscribe to Premium</Text>
      <View style={styles.toggleContainer}>
        <TouchableOpacity
          style={[
            styles.toggleButton,
            subscriptionPeriod === "monthly" && styles.selectedToggle,
          ]}
          onPress={() => {
            setSubscriptionPeriod("monthly");
            setSelectedPlan(plansData.monthly[1]);
          }}
        >
          <Text
            style={[
              styles.toggleText,
              subscriptionPeriod === "monthly" && styles.selectedToggleText,
            ]}
          >
            Monthly
          </Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={[
            styles.toggleButton,
            subscriptionPeriod === "annually" && styles.selectedToggle,
          ]}
          onPress={() => {
            setSubscriptionPeriod("annually");
            setSelectedPlan(plansData.annually[1]);
          }}
        >
          <Text
            style={[
              styles.toggleText,
              subscriptionPeriod === "annually" && styles.selectedToggleText,
            ]}
          >
            Annual
          </Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={[
            styles.toggleButton,
            subscriptionPeriod === "lifetime" && styles.selectedToggle,
          ]}
          onPress={() => {
            setSubscriptionPeriod("lifetime");
            setSelectedPlan(plansData.lifetime[1]);
          }}
        >
          <Text
            style={[
              styles.toggleText,
              subscriptionPeriod === "lifetime" && styles.selectedToggleText,
            ]}
          >
            Lifetime
          </Text>
        </TouchableOpacity>
      </View>
      <ScrollView contentContainerStyle={styles.scrollContainer}>
        <View style={styles.planContainer}>
          {plans.map((plan) => (
            <TouchableOpacity
              key={plan.id}
              style={[
                styles.planBox,
                selectedPlan.id === plan.id && styles.selectedPlanBox,
              ]}
              onPress={() => handlePlanSelect(plan)}
            >
              <Text style={styles.planName}>{plan.name}</Text>
              <Text style={styles.planPrice}>{plan.price}</Text>
              {plan.billed && (
                <Text style={styles.planBilled}>{plan.billed}</Text>
              )}
            </TouchableOpacity>
          ))}
        </View>
        <View style={styles.featuresList}>
          {selectedPlan.features.map((feature, index) => (
            <View style={styles.featureItem} key={index}>
              <Icon name="check" type="material" color="#A8BCA1" />
              <Text style={styles.featureText}>{feature}</Text>
            </View>
          ))}
        </View>
      </ScrollView>
      {isPremiumPlan && (
        <TouchableOpacity
          style={styles.subscribeButton}
          onPress={() => alert("Premium Will be Released Soon!")}
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
    padding: 20,
    paddingTop: 30,
  },
  backButton: {
    alignSelf: "flex-start",
    top: 30,
    right: 10,
    borderRadius: 8,
    width: 40,
    padding: 4,
    zIndex: 1,
  },
  header: {
    fontSize: 24,
    fontWeight: "bold",
    color: "#F5F5F5",
    textAlign: "center",
    marginBottom: 20,
  },
  toggleContainer: {
    flexDirection: "row",
    justifyContent: "center",
    marginBottom: 20,
  },
  toggleButton: {
    paddingVertical: 10,
    paddingHorizontal: 20,
    borderWidth: 1,
    borderColor: "#ddd",
    borderRadius: 5,
    marginHorizontal: 5,
  },
  selectedToggle: {
    borderColor: "#5FCB73",
  },
  toggleText: {
    color: "#F5F5F5",
    fontSize: 16,
  },
  selectedToggleText: {
    color: "#5FCB73",
  },
  scrollContainer: {
    flexGrow: 1,
    paddingBottom: 80, // Ensure enough space for the subscribe button
  },
  planContainer: {
    flexDirection: "row",
    justifyContent: "space-around",
    marginBottom: 20,
  },
  planBox: {
    flex: 1,
    padding: 20,
    backgroundColor: "#1e1e1e",
    borderRadius: 10,
    borderWidth: 1,
    borderColor: "#1e1e1e",
    alignItems: "center",
    marginHorizontal: 5,
  },
  selectedPlanBox: {
    borderColor: "#5FCB73",
  },
  planName: {
    fontSize: 20,
    fontWeight: "bold",
    color: "#F5F5F5",
    marginBottom: 5,
    fontStyle: "italic",
  },
  planPrice: {
    fontSize: 24,
    fontWeight: "bold",
    color: "#5FCB73",
  },
  planDuration: {
    fontSize: 16,
    color: "#ddd",
    marginTop: 5,
  },
  planBilled: {
    fontSize: 16,
    color: "gray",
    marginTop: 5,
  },
  featuresList: {
    marginBottom: 20,
  },
  featureItem: {
    flexDirection: "row",
    alignItems: "center",
    marginBottom: 10,
  },
  featureText: {
    color: "#F5F5F5",
    marginLeft: 10,
    fontSize: 16,
  },
  subscribeButton: {
    position: "absolute",
    bottom: 50,
    left: 20,
    right: 20,
    backgroundColor: "#282C35",
    borderRadius: 8,
    padding: 15,
    alignItems: "center",
  },
  subscribeButtonText: {
    color: "#5FCB73",
    fontSize: 18,
    fontWeight: "bold",
  },
});
